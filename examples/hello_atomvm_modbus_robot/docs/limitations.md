# 既知の制約

このページは virtual robot application と3-node構成に固有の制約をまとめます。FC-100 byte-stream carrier 自体の制約は
[Modbus distributed Erlang example の既知の制約](../../hello_atomvm_modbus_disterl/docs/limitations.md)、個別の実測結果は
[作業記録](worklog/README.md) を参照してください。

## 構成と通信経路

- 固定された `controller`、`drive`、`sensors` の3 role、Unit ID 1 / 2 の構成だけを対象とします。dynamic discovery、routing、
  4 node 以上への拡張は実装していません。
- Modbus Server である Drive と Sensors は bus を自発的に駆動できません。両者の application message は Controller が relay し、
  すべての physical transaction は1個の Modbus Client が直列化します。
- Controller は Drive / Sensors ごとに独立した distribution stream を持ちますが、physical UART と AVModbus Client を共有します。
  短時間の同時 producer は両 role とも完全配送しましたが、64 messages / role の継続負荷では両 carrier session が再生成されました。
- 3-node distribution は AtomVM v0.7.0-beta.0 に対する local multi-connection tick patch を必要とします。公式 image のまま動作する
  production 構成ではありません。

## Buffer と backpressure

- FC-100 carrier の outgoing queue は stream ごとに default 8,192 payload bytes / 256 chunks です。Controller の2 stream は独立した
  上限を持ちます。
- 上限は carrier が保持する payload の合計であり、binary、Erlang term、process mailbox、distribution controller を含む VM heap
  全体の上限ではありません。application process の mailbox に明示的な件数上限はありません。
- queue 上限を超えた write は `{:error, :queue_full}` となり、carrier は fail fast して session を切り替えます。queue 済みまたは
  in-flight の stream data は破棄されるため、回復は application の timeout / retry に依存します。
- `MODBUS_MAX_QUEUED_BYTES` と `MODBUS_MAX_QUEUED_CHUNKS` は compile-time configuration です。値を増やすことは delivery guarantee
  ではなく、ESP32-C5 の memory 使用量も増やします。
- concurrent traffic probeはroleごとに1 messageだけを未確認状態にするapplication ACKを使用します。ACK timeout時のretryは
  boundedですが、collector crashやretry上限超過後のdurable resumeは実装していません。

## Command delivery と state

- Drive は直近32件の `{request_id, command, result}` を RAM に保持します。同じ ID / command の近接 retry は cached result を返し、
  movement を再実行しません。
- cache eviction 後の古い ID、または Drive reboot 後の retry は新規 command として実行されます。rover state、request cache、
  sensor sequence、last sample は reboot で失われます。
- Controller は起動ごとの random value から request ID range を開始しますが、永続 namespace や過去 boot との collision 検出は
  ありません。durable delivery と exactly-once execution は保証しません。
- Sensors sample request と Controller relay は idempotent な transaction ID を持ちません。timeout 後の自動 mission resume、partial
  progress の照合、再取得した sample の重複排除は未実装です。

## Failure detection と recovery

- 現在の AtomVM-to-AtomVM / alternative carrier 構成では remote PID に対する `Process.monitor/1` が `badarg` となるため、
  application readiness lease を使用します。
- default の heartbeat 30秒、lease 75秒は即時検出を目的としません。message delivery が lease より遅れると false positive が
  発生します。5秒 lease では実機で両 role の誤 expiry を確認しました。
- Controller は sensor-driven mission を同期的に実行します。mission command の reply 待ち中は readiness lease を評価しないため、
  remote outage の検出は command timeout または mission 終了後まで遅れます。
- Drive / Sensors の独立 reboot 後に distribution と application probe が復旧することは確認済みですが、進行中 mission の自動再開や
  rover state の reconciliation は行いません。
- peer session change で古い reader を閉じると、回復可能な場合でも AtomVM console に
  `{serial_read_error, closed}` の crash report が表示されます。
- 64 messages / role の concurrent run では23–24 messages受信後に両 carrier session が変わり、distribution 自体は再接続しましたが、
  session change 前の producer process は再開されませんでした。collector は残りを欠損として timeout します。transport reconnect は
  application workload の再開を保証しません。
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
- readiness healthは最初のController ACKを受け取った後のconnectionだけを監視します。初回handshakeを確立できないnodeには既存のannounce retryを
  続け、health restartは行いません。persistent workload ownerとdurable mission resumeは未実装です。

## 性能と用途

- shared half-duplex bus、polling、stop-and-wait、distribution framing により、direct UART distribution より latency が大きくなります。
  115,200 baud の短時間 application soak では両 remote の平均 RTT は約3.18秒でした。
- reply loss fault injection は application reply の破棄だけを再現します。RS485 cable fault、partial RTU frame、node power loss、
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
- `MODBUS_FAULT_*` はServer responseだけを破棄する診断用設定です。双方向のRS485 cable断、partial frame、電源断を再現せず、
  通常運用のrecovery機構として使用するものではありません。
- Server adapterを再生成するとresponse faultのcountとdelayも初期化され、同じfaultが再度armされます。recovery試験ではtraffic完了後に
  2回目のblackoutが始まったため、settled metricsは通常時のqueue drainを表しませんでした。
- physical actuator、real-time control、safety-critical control、production robot には使用しません。
