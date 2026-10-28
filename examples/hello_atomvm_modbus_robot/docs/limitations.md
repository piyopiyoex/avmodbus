# 既知の制約

このページは virtual robot application と3-node構成に固有の制約をまとめます。FC-100 byte-stream carrier 自体の制約は
[Modbus distributed Erlang example の既知の制約](../../hello_atomvm_modbus_disterl/docs/limitations.md)、個別の実測結果は
[作業記録](worklog/README.md) を参照してください。

## 構成と通信経路

- 固定された `controller`、`drive`、`sensors` の3 role、Unit ID 1 / 2 の構成だけを対象とします。dynamic discovery、routing、
  4-node以上への拡張は実装していません。Controllerのtransport setupはpeer descriptor list駆動へ変更しましたが、これは
  adapter lifecycleの準備だけであり、第4 roleのapplication protocol、firmware、readiness、metricsは未実装です。
  3 remote peers以上はまずhost modelで検証し、deviceを1台ずつ追加することは通常のroadmap milestoneにしません。
  詳細は[ADR 0020](adr/0020-model-scale-on-host-instead-of-adding-devices.md)を参照してください。
- Modbus Server である Drive と Sensors は bus を自発的に駆動できません。両者の application message は Controller が relay し、
  すべての physical transaction は1個の Modbus Client が直列化します。
- Controller は Drive / Sensors ごとに独立した distribution stream を持ちますが、physical UART と AVModbus Client を共有します。
  各adapterのpollはround-robin schedulerが直列に開始し、到達不能なUnitのqueue待ちで正常Unitのrequest deadlineを失わないようにします。
  短時間の同時 producer は両 role とも完全配送しましたが、64 messages / role の継続負荷では両 carrier session が再生成されました。
- 3-node distribution は AtomVM v0.7系に対する local multi-connection tick patch を必要とします。2026-10-23時点の
  `release-0.7` snapshot `18b35870`にも問題が残ることをsourceと独立testで確認しています。これはAVModbus側の既知問題として
  文書化し、local compatibility patch `a1069573`で検証します。同snapshotとpatchからbuildしたruntimeは3台の実機で
  2 connection、remote messaging、mission後90秒の維持まで確認しましたが、公式imageのまま動作するproduction構成ではありません。

## バッファとバックプレッシャー

- FC-100 carrier の outgoing queue は stream ごとに default 8,192 payload bytes / 256 chunks です。Controllerはこれに加えて、
  全client streamで共有するdefault 8,192 bytes / 256 chunksのglobal上限を持ちます。
- 上限は carrier が保持する payload の合計であり、binary、Erlang term、process mailbox、distribution controller を含む VM heap
  全体の上限ではありません。application process の mailbox に明示的な件数上限はありません。
- queue 上限を超えた write は `{:error, :queue_full}` となり、carrier は fail fast して session を切り替えます。queue 済みまたは
  in-flight の stream data は破棄されるため、回復は application の timeout / retry に依存します。
- `MODBUS_MAX_QUEUED_BYTES` と `MODBUS_MAX_QUEUED_CHUNKS` は compile-time configuration です。値を増やすことは delivery guarantee
  ではなく、ESP32-C5 の memory 使用量も増やします。
- Controllerのglobal上限も`ROBOT_MULTINODE_GLOBAL_MAX_QUEUED_BYTES`と
  `ROBOT_MULTINODE_GLOBAL_MAX_QUEUED_CHUNKS`によるcompile-time configurationです。global拒否は
  `{:error, :global_queue_full}`となり、該当streamだけがsessionを切り替えます。peer間の公平な予約や待機型backpressureは提供しません。
- host modelでstream別defaultを単純合算すると、32 remote peersのconfigured payload limitは262,144 bytes / 8,192 chunksに
  なります。これは事前確保量ではありませんが、3台実測のminimum free heap 68,848 bytesを超えるため、
  current defaultをN streamsへ複製できるとは主張しません。global budgetによりcarrier payload合計は制限しますが、peer数依存の
  process / mailbox / distribution memoryと実heapの増分は未測定です。
- concurrent traffic probeはroleごとに1 messageだけを未確認状態にするapplication ACKを使用します。ACK timeout時のretryは
  boundedですが、collector crashやretry上限超過後のdurable resumeは実装していません。collectorの全体timeoutは通信断や
  handshake中も進み、停止または延長されません。baseline送信、operatorの切断保持、再接続、残り送信を含む値に設定する必要があります。

## コマンド配送と状態

- Drive は直近32件の `{request_id, command, result}` を RAM に保持します。同じ ID / command の近接 retry は cached result を返し、
  movement を再実行しません。
- unguarded commandではcache eviction後の古いID、またはDrive reboot後のretryが新規commandとして実行されます。sensor-driven missionは
  開始時のDrive boot IDへcommandを束縛し、別bootでは実行せずindeterminate outcomeとして停止します。同一bootでcache eviction後に
  古いIDを再利用する場合は保護しません。
- rover state、request cache、sensor sequence、last sampleはrebootで失われます。boot guardはstateを復元せず、旧bootで未確認commandが
  実行されたかも確定しません。
- Controller は起動ごとの random value から request ID range を開始しますが、永続 namespace や過去 boot との collision 検出は
  ありません。durable delivery と exactly-once execution は保証しません。
- Sensors sample request と Controller relay は idempotent な transaction ID を持ちません。timeout 後の自動 mission resume、partial
  progress の照合、再取得した sample の重複排除は未実装です。

## 障害検出と復旧

- 現在の AtomVM-to-AtomVM / alternative carrier 構成では remote PID に対する `Process.monitor/1` が `badarg` となるため、
  application readiness lease を使用します。
- default の heartbeat 30秒、lease 75秒は即時検出を目的としません。message delivery が lease より遅れると false positive が
  発生します。5秒 lease では実機で両 role の誤 expiry を確認しました。
- sensor-driven missionはlocal workerで実行し、Controller health loopはmission commandのreply待ち中もreadiness ACKとleaseを
  処理します。ただし起動時probe、recovery probe、任意のsoakには同期処理が残り、すべてのapplication workloadでhealth loopの
  応答性を保証するものではありません。
- Drive / Sensorsの独立reboot後にdistributionとapplication probeが復旧することは確認済みです。Drive rebootをまたぐ未確定commandは
  新bootで再実行せずmissionを停止します。Controllerのhealth loopは継続し、新bootにguardしたread-only `:status`を別workerで
  snapshotとして記録しますが、旧bootでの実行有無は確定せず、進行中missionの自動再開やrover stateのreconciliationも行いません。
- snapshot確認後にControllerをresetすると、新しいrequest ID rangeと現在のDrive boot guardで別missionを開始します。Driveを同時に
  resetしない限りrover stateは保持されます。Controller resetはstate初期化、旧missionのresume、snapshotを承認する対話的protocolでは
  ありません。
- peer session change で古い reader を閉じると、回復可能な場合でも AtomVM console に
  `{serial_read_error, closed}` の crash report が表示されます。
- AtomVMのdistribution setup timerは固定7秒です。Drive / Sensorsを先行起動してsetupがtimeoutすると、
  `net_kernel.start/2`は成功済みでも`serial_dist`の片側stateが残ります。初回readiness ACK待ち8秒でremote側の
  distributionをbounded restartすることで、Drive / Sensorsの両方がboard resetなしで復旧することを実機確認しました。
  これは7秒timerを延長せず、stale stateをremote自身がteardownするexample側の復旧です。
- 64 messages / role の concurrent run では23–24 messages受信後に両 carrier session が変わり、distribution 自体は再接続しましたが、
  session change 前の producer process は再開されませんでした。collector は残りを欠損として timeout します。transport reconnect は
  application workload の再開を保証しません。
- traffic開始messageをSensors linkのblackout中に1回だけ送った初期試験では、再接続後もSensors producerは開始せず、
  `started=false`、0 / 16のままcollectorがtimeoutしました。follow-upではrole別start ACKとbounded retryを追加し、再接続後に
  Sensors producerを開始して16 / 16を配送しました。同じrun IDの再受理はremoteで重複起動しません。ただしrun ID guardはvolatileで、
  physical device rebootをまたぐdurable exactly-once startや、複数の同時jobを管理するregistryではありません。
- 3台のconsoleを同時取得した再現runでは、Sensors側のoutgoing queueが`:queue_full`になり、fail-fast resetが発生する順序を確認しました。
  Controllerで取得するadapter metricsはController側の2 queueだけで、Drive / Sensors側のoutgoing queue使用量を表しません。
- Sensors が request を受理した後の FC-100 response だけを連続して破棄する試験では、Controller は `net_tick_timeout` で接続を閉じましたが、
  request と tick を受信し続けた Sensors は古い distribution connection を閉じませんでした。response 破棄終了後に Modbus polling と
  carrier byte delivery は復帰しても、distribution handshake は再開されませんでした。
- 上記の非対称 half-open 状態では application ACK timeout による same-sequence retry は古い distribution stream に送られ、retry 上限で
  producer が停止しました。physical carrier の復帰は distribution connection と application workload の復帰を意味しません。
  stale remote connection を明示的に teardown する必要があります。
- opt-inのtraffic probeでは、最初のACK timeoutをlocal ownerへ通知し、remote側の`net_kernel`全体をstop / restartする回復を実装しました。
  16+16 runは同じproducer / sequenceで再開できましたが、これは1 connectionだけを持つDrive / Sensors向けです。特定peerだけのdisconnect、
  Controller側の複数connectionを保ったまま任意のlinkを閉じるAPI、一般のmission recoveryは提供しません。
- opt-inのremote health detectorはconnection ID付きreadiness ACKを監視し、application trafficがないresponse blackoutでもSensorsだけを
  再接続できました。古いconnectionのACKは無視し、restart回数はboard boot単位で制限します。ただしtimeoutはfailureの証明ではなく、
  bus congestionやscheduler delayでもfalse positiveになり得ます。
- `net_kernel.stop/0`は終了完了前に`:ok`を返す場合があります。旧`:net_kernel`の登録解除を50 ms間隔、最大40回待ってから再開しますが、
  2秒以内に停止しなければ回復を終了します。restart上限はrebootで初期化され、正常化後も同じboot中には補充しません。
- restart上限を使ったbootのまま物理切断試験を繰り返すと、次の障害では`remote health restart budget exhausted`となります。
  反復試験で毎回自動restartを評価する場合は、各run前に対象remoteをclean bootし、起動時handshakeで上限を消費していないことを
  consoleで確認します。
- 初回復旧と接続後のremote healthは、同じboard boot単位のrestart budgetを共用します。既定の上限は1回で、
  初回復旧で消費した場合、そのbootで後発したconnection outageに追加restartは行いません。正常接続後もbudgetは
  補充しません。上限を増やすと、進行中の遅いhandshakeを次の8秒期限で切断する可能性があるため、
  実機baselineは1回のみです。persistent workload ownerとdurable mission resumeは未実装です。
- paired-wire配線でSensorsまたは右端DriveのA/Bを外した試験では、残るpeerも停止しました。物理配置上の位置と電気的なbranch isolationは
  同義ではなく、trunkをremovable nodeの端子に依存させる配線は独立peer faultの検証に使えません。
- breadboard上のcontinuous A/B trunkとnode別branchによる初回試験では、Sensorsの最後のACKから48,760 ms後にremote healthが切断を
  検出し、Drive distributionは切断されずheartbeatを継続しました。ただし反復時には各adapterの独立pollによるshared Clientの
  deadline starvationを再現し、正常なUnit 1もtimeoutしてDrive connectionを失いました。
- round-robin poll scheduler導入後の2回のbranch切断では、Unit 2が約2秒timeoutを繰り返す間もUnit 1は約180–225 msで成功し、
  transaction failure 0のままDrive connectionを維持しました。未使用のrestart budgetを持つrunではACK欠落48,470 msでSensorsを
  自動再起動し、branch復帰後に手動resetなしでSensors / Drive両probeまで完了しました。
- 128+128 flow-controlled traffic中の2 clean-boot runでは、Sensors branch切断中もDrive connectionを維持し、SensorsはACK欠落
  36,943–38,388 msでdistributionを再起動しました。branch復帰後に同じsequenceから再開して両roleを完全配送しました。ただし
  Drive transaction failureは0–1、duplicate sampleは3–11件、elapsedは451,811–568,227 msと幅がありました。2回目の30秒snapshotでは
  Driveにreadiness trafficを含み得る117 bytes / 2 outstandingがあり、常に30秒で両queueが0になるとは保証しません。
- 90秒remote health timeoutを使った64+64 runでは、約37秒のphysical応答停止後もrestartせず同じconnectionで復帰し、欠損・重複
  なしで完了しました。一方、操作時間が約1分を超えたcalibrationではControllerが`net_tick_timeout`でSensorsを閉じた後、Sensorsの
  restartが`net_kernel_stop_timeout`となり、Unit 2のphysical応答も停止しました。短時間復帰の成功をlease / tick境界を超える切断へ
  外挿できません。条件は[worklog](worklog/2026-10-24-extended-fault-recovery.md)を参照してください。
- 約199秒のidle切断では、Sensors restart成功後にbudgetを使い切り、復線後もdistribution handshakeは成立しませんでした。
  physical pollingは約10分復帰しましたが、Sensors minimum free heapが14,428 bytesまで低下した後、Unit 2も再び応答不能になりました。
  Drive connectionは維持しました。原因processは未確定であり、current v0.7 snapshotのruntime blockerとして
  [worklog](worklog/2026-10-25-idle-180-second-disconnect.md)に記録しています。
- Stage 7の約97秒の操作応答区間では、ACK gap 118,168 msでrestartを開始した後、`:net_kernel`の登録解除を3秒以内に
  確認できず`net_kernel_stop_timeout`となりました。`kernel_start_started`には到達せず、Sensors free heapはrestart開始時も
  約91 KiBでした。長時間通信断のfailureはmemory低下だけでは説明できず、同じruntime snapshotでもkernel stop段階で
  終了する場合があります。詳細は
  [現行ポリシーの基準値](worklog/2026-10-26-stage-7-current-policy-baseline.md)を参照してください。
- Stage 7のdeferred restartは、有効なFC-100 exchangeが長時間途切れた物理branch切断だけを比較対象にします。既定値では無効で、
  remote health timeoutやrestart上限は変更しません。連続exchangeの受理はremote側UARTの復帰を示しますが、responseのController到達、
  distribution handshake、application probeの成功までは保証しません。非対称response blackoutではServer側exchangeが継続するため、
  この条件では復帰を検出できません。
- clean bootの3台実機では、約350.8秒のFC-100 exchange gap後に2回の有効exchangeを確認し、Sensorsのkernel restart、
  readiness ACK、Controller再接続、Sensors / Drive両probeまで自動復旧しました。transport readyから両probe成功までは約10.6秒で、
  Drive connectionを維持しました。ただしcurrent policyのfailure試験は約97秒の操作応答区間であり、同一時間の対照試験では
  ありません。この単一runから任意の長時間切断、反復障害、負荷、electrical conditionでの回復を保証しません。詳細は
  [transport復帰後のrestart保留](worklog/2026-10-26-stage-7-deferred-restart.md)を参照してください。
- Stage 8では目標120秒・300秒のbranch切断を各policyで2回ずつ反復した。Currentはphysical transport復帰前にrestart budgetを
  消費して0 / 4、deferredは観測した166.510–393.908秒のFC-100 gap後に4 / 4で復旧した。Deferredのtransport readyから
  Sensors / Drive両probe成功までは10.690–12.119秒だった。ただしobserverのgapはadapter単位で、adapter再生成前の切断区間を
  含まない場合がある。2 runs / conditionは探索的な結果であり、非対称response blackoutを扱えないためdeferredはopt-inを維持する。
  詳細は[Stage 8反復試験](worklog/2026-10-26-stage-8-recovery-repeatability.md)を参照してください。
- Stage 9の非対称response blackoutでは、Sensorsがrequestを受理しながら180 responsesを破棄する約83秒のfaultを各policyで2回
  実行した。Currentは2 / 2でController transaction復帰後にrestartして両probeまで復旧し、deferredは2 / 2でrestartを保留したまま
  180秒以内に復旧しなかった。4 runsすべてでDriveを維持した。`request_accepted`と`response_returned`はいずれもControllerによる
  response受信を保証しないため、非対称障害には双方向成立を示す追加signalが必要である。詳細は
  [Stage 9実機比較](worklog/2026-10-27-stage-9-asymmetric-response-blackout.md)を参照してください。
- Stage 10のhealthy lifecycle probeでは、Sensorsの`net_kernel`登録解除を88 ms、再開までを合計204 msで完了し、Controller再接続と
  Drive維持を確認しました。一方、Sensors branch切断中のprobeではstopは67 msで完了し、過去の`net_kernel_stop_timeout`は
  再現しませんでした。`net_kernel.start/2`成功後のsetup timeoutと、branch復帰後にphysical FC-100だけが再開する状態を観測しました。
  Distributionは自動復旧せず、Sensors free heapは最小45,308 bytesまで低下しました。原因は未特定です。詳細は
  [Stage 10 lifecycle probe](worklog/2026-10-28-stage-10-lifecycle-probe.md)を参照してください。
- 同一Sensors bootで短時間のbranch切断を3回反復した試験では、90秒remote health timeoutへ達せず、同じconnection IDのまま
  3回とも復帰しました。faultを含む2 runsと後続runは両role 64 / 64、欠損・重複なしで完了し、restart budget消費と
  global queue rejectionは0でした。ただし操作時刻とserial logを共通時計で精密測定しておらず、Driveにもfaultを含むrunごとに
  単発transaction timeoutが1件あったため、正確な30秒境界や正常peerへの無影響は保証しません。詳細は
  [worklog](worklog/2026-10-25-repeated-branch-disconnect.md)を参照してください。
- handshake中には複数の`unexpected`、`unsupported_name`、`invalid_challenge`、`no_link_manager_response`、timeoutが発生しています。
  retryは最終的に収束しましたが、復旧時間の上限や任意の電気条件でのfailure isolationを保証しません。termination / biasも個別測定して
  いません。
- paired-wire試験では物理link復帰だけで2 linkが完全復旧せずController RESETを要しました。branch配線の成功は、全種類のbus障害から
  全streamが自動再同期する保証ではありません。
- mission worker分離前のremote ACK timeout 25秒は通常mission中に25,537 msのACK gapを障害と誤判定しました。分離後に
  10秒announce、通常mission、32+32 flow-controlled traffic、30秒settlingを含む単一runで測ったhigh-waterは両roleとも
  11,532 msでした。各connectionの初回ACKはhandshake時間を含むため測定から除外しています。この差は改善を示すprofile baselineで、
  25秒を一般的な安全値に認定するものではありません。announce interval、bus負荷、handshake、queue遅延より十分大きく設定する
  必要があります。
- 同じ10秒announceを256+256 flow-controlled trafficへ延長した無障害runでは、ACK gap high-waterがDrive 23,586 ms、Sensors
  23,995 msまで伸びました。health restartは0でしたが25秒との差は1,414 ms / 1,005 msしかなく、短時間runのhigh-waterをtimeout
  設計へ外挿できません。

## 性能と用途

- `RobotSim.MultinodeModel`はhost上の論理modelです。poll順序、service time、bounded queue、session replacementは
  deterministicに再現しますが、RS485のelectrical behavior、RTU framing、UART turnaround、AtomVM scheduler、VM heapを再現しません。
  model内のqueueは抽象的なlogical item単位であり、FC-100 payload byte、fragment chunk、process mailboxと同じではありません。
  1、2、3、8、32 remote peersのhost resultは、4台以上のphysical distributionが動作する根拠ではありません。
- host modelではfailed peerがいても正常peerのpoll回数は維持しましたが、failed peerのservice timeoutは各roundの
  elapsed timeへ加算されます。poll fairnessはlatency fairnessやdeadline guaranteeを意味しません。
- shared half-duplex bus、polling、stop-and-wait、distribution framing により、direct UART distribution より latency が大きくなります。
  115,200 baud の短時間 application soak では両 remote の平均 RTT は約3.18秒でした。
- reply loss fault injection は application reply の破棄だけを再現します。今回実施したRS485 A/B切断、partial RTU frame、node power loss、
  simultaneous reboot と同じ failure modelではありません。
- 20 messages / role の overload profile は完全配送しましたが、Drive link で1回の2秒 transaction timeoutを観測しました。
  64 messages / role の run はproducer rateがbusの排出速度を上回ってremote queueを飽和させたため未完了です。これはapplication-level
  flow controlなしの負荷条件であり、carrierの安全な持続throughputを示す値ではありません。
- window 1のapplication ACKを追加した同じ64+64 profileは163,039 msで完全配送しました。response blackoutからのremote restartを含む
  16+16 profileも完全配送しましたが、いずれも単一runです。繰り返す通信断、長時間memory stability、任意のworkloadに対する
  sustained throughputを保証しません。
- window 1の256+256 profileは627,792 msで完全配送し、queue high-waterはDrive 279 bytes / 4 chunks、Sensors 162 bytes /
  2 chunksでした。Controller free heapは開始時約89 KB、30秒settled時約85 KB、minimum watermark 70,736 bytesでした。これは単一の
  10分runであり、数時間のmemory stabilityやremote側VM全体のmemory推移を保証しません。
- 2026-10-23の別の256+256 profileも783,317 msで完全配送し、Controller側queue high-waterは両role 200 bytes / 3 chunks、
  minimum free heapは68,848 bytes、30秒後の両queueは0でした。2回の所要時間とmetricsは同一ではなく、これらの単一runから
  sustained throughputやmemory上限を保証しません。
- 16+16 messagesと270秒idleを12回反復する64分30秒profileは全runを完全配送し、restartとglobal rejectionは0でした。
  periodic free heapの単調減少はありませんでしたが、Sensorsでretry可能なtransaction timeoutを8件観測しました。
  この1回のprofileから数時間・数日の安定性やerror-freeなphysical transportを保証しません。詳細は
  [worklog](worklog/2026-10-25-one-hour-active-idle-endurance.md)を参照してください。
- `MODBUS_FAULT_*` はServer responseだけを破棄する診断用設定です。双方向のRS485 cable断、partial frame、電源断を再現せず、
  通常運用のrecovery機構として使用するものではありません。
- 以前はServer adapterを再生成するとresponse faultのcountとdelayも初期化され、同じfaultが再度armされました。現在の既定値では
  replacement adapterのdrop countを0にしてboard boot中のfaultを最大1回にします。`MODBUS_FAULT_REARM_ON_RESTART=true`で以前の
  反復動作へ戻せます。fault発生前に別理由でrestartした場合もreplacementではarmせず、device rebootで再びarmします。
- physical actuator、real-time control、safety-critical control、production robot には使用しません。
