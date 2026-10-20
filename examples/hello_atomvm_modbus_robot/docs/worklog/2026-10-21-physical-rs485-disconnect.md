# 物理RS485切断・再接続 — 2026-10-21

## 目的

3-node distributed Erlangがidleの状態でSensorsのRS485 A/Bを物理的に外し、remote healthの検出、残るpeerへの影響、
再接続後の自動復旧範囲を確認する。Server responseだけを破棄する既存fault injectionとは異なり、requestとresponseの両方向が
失われる実配線の障害を対象とする。

## 実機条件

- 3 × Seeed Studio XIAO ESP32-C5
- shared two-wire RS485、115,200 baud、FC-100 chunk payload 96 bytes
- AtomVM v0.7.0-beta.0と既存multi-connection local patch
- concurrent trafficは無効
- Sensorsだけ`ROBOT_MULTINODE_REMOTE_HEALTH_ENABLED=true`
- Sensorsのannounce interval 10,000 ms、ACK timeout 45,000 ms、restart上限1回 / boot
- Controllerのreadiness leaseは既定75,000 ms

物理配置とこの試験時のportは次のとおりだった。

| 位置 | Role | Port | Base MAC | Unit ID |
| --- | --- | --- | --- | ---: |
| 左 | Controller | `/dev/ttyACM2` | `38:44:BE:A5:05:14` | client |
| 中央 | Sensors | `/dev/ttyACM1` | `10:BD:A3:CF:09:04` | 2 |
| 右 | Drive | `/dev/ttyACM0` | `38:44:BE:A5:04:DC` | 1 |

各boardのRESETを順に押し、consoleのboot logとrole registrationから配置を確定した。port番号は再接続順で変わり得るため、
この表を一般的な固定割り当てとして扱わない。

## 事前のtimeout確認

最初にSensorsのACK timeoutを25,000 msとして起動したところ、配線を外す前の通常mission中にACK gap 25,537 msでremote healthが
distributionを再起動した。shared busのhandshakeとmission trafficでは25秒を超えるACK遅延が起こり得るため、この値はfalse positiveを
避けられない。試験用timeoutを45,000 msへ変更し、50秒以上のidle heartbeatが正常にACKされることを確認してから物理切断を行った。

## Paired-wireでのSensors切断時の観測

中央のSensors transceiverからA/Bを外し、USB電源とsignal groundは維持した。Sensorsが最後にreadiness ACKを受けたのは
08:21:49で、その後はheartbeatを10秒ごとにqueueへ追加したがdelivery ACKを受信しなかった。

- 08:21:56: ControllerでUnit 1のpoll timeoutを記録した
- 08:22:38: Sensorsが`{:readiness_ack_timeout, 48691}`を検出した
- 08:22:38: Sensorsがlocal distributionをstop / restartし、新しいcarrier sessionを開始した
- 08:22:48: ControllerでDriveのreadiness leaseが失効した
- 08:23:02: Controller側のDrive / Sensors connectionがともに`net_tick_timeout`で終了した
- 08:23:03: ControllerでSensorsのreadiness leaseが失効した

Sensorsだけを外す意図だったが、Driveも継続通信できなかった。今回の配線は中央boardの端子を外してもController–Drive間の
trunkを独立に維持する構成ではなかったか、抜き差し時の電気的擾乱がbus全体へ波及した可能性がある。この結果から
「Unit 2だけの物理障害中もUnit 1が継続する」とは判断できない。

## Paired-wireでのSensors再接続時の観測

A/Bを同じ極性で戻すとModbus RTU pollingは再開した。

- 08:23:32: ControllerがSensorsのcarrier session changeを検出した
- 08:23:52–08:24:01: Sensors handshakeで一時的な`unexpected`、`unsupported_name`、timeoutを記録した
- 08:24:12: ControllerがSensors distributionのreconnectを記録した
- 08:24:15: Sensorsへのrecovery probeが成功した
- DriveのModbus byte deliveryは再開したが、Drive distributionのreconnectは完了しなかった
- 08:25:15: ControllerのDrive recovery probeがtimeoutした

このため、物理linkの復帰だけでは2本のdistribution connectionは完全に自動復旧しなかった。Sensorsのremote healthはboot単位の
restart上限1回を08:22:38に使用済みで、08:25:04には上限到達を記録した。

左のControllerだけをRESETすると、Drive / Sensorsの両方でreadiness heartbeatとconnection ID付きACKが再開した。再起動直後の
connection logはconsole監視の切り替え中で取得できなかったが、08:30:15–08:33:07にSensorsは10秒周期、Driveは30秒周期で複数回の
双方向deliveryを継続した。readiness messageとACKはdistribution上のapplication messageであるため、両linkの再確立を確認できる。

## Paired-wire Sensors試験の結果

| 確認項目 | 結果 |
| --- | --- |
| Sensorsの物理切断検出 | 成功。最後のACKから48,691 msで検出 |
| remote側のbounded restart | 成功。1回だけ再起動し、上限到達後はstormを抑止 |
| 切断中のDrive継続 | 未達。今回の抜線方法ではbus全体に影響 |
| A/B復帰後のModbus通信 | 成功 |
| A/B復帰だけによる2 link完全復旧 | 未達。Sensorsは再接続したがDriveは未完了 |
| Controller RESET後の2 link復旧 | 成功 |
| 25秒health timeout | 不適。正常mission中にfalse positive |
| 45秒health timeout | このidle試験では切断前にfalse positiveなし |

## Sensors切断試験後の復元

Drive、Sensors、Controllerをtraffic probe、response fault、remote healthがすべて既定の無効状態でrebuildし、3台へflashした。

| Role | `main.avm` size |
| --- | ---: |
| Drive | 254,696 bytes |
| Sensors | 254,668 bytes |
| Controller | 256,916 bytes |

通常の3-node起動ではControllerがSensors、Driveの順に接続し、両roleへのprobeが成功した。sensor-driven missionは3 stepを完了し、
08:57:46に最終state `{x_mm: 200, y_mm: 0, heading_deg: 90}`を確認した。診断用の45秒timeout設定は実機に残していない。

## 右端Driveの追試

現在の配線を変えずに中央nodeの影響を避けられるか確認するため、右端Driveを対象に同じ試験を行った。利用者からは3台をpair wireで
series状に接続していると説明された。回路図、A/B抵抗、termination / biasの個別測定は行っていないため、trunk切断と電気条件変化の
どちらが支配的だったかは区別しない。

Driveだけにremote healthを有効化し、announce interval 10,000 ms、ACK timeout 45,000 ms、restart上限1回 / bootとした。
切断前はDriveが10秒周期で6回以上、Sensorsが30秒周期で2回以上連続してACKを受信した。

- 10:29:13: Sensorsが最後のACKを受信した
- 10:29:17: Driveが最後のACKを受信した
- 10:30:05: Driveが`{:readiness_ack_timeout, 48693}`を検出し、distributionを再起動した
- 10:30:23: Controller側のDrive / Sensors connectionがともに`net_tick_timeout`で終了した
- 10:30:31: ControllerでDrive / Sensors両方のreadiness leaseが失効した

右端DriveのA/Bを外した場合もSensors通信は継続しなかった。現在の配線では物理的な右端を外すだけでも、残る2台の独立busを維持できない。

DriveのA/Bを戻した後は10:37:24にControllerがDriveのcarrier session changeを検出した。複数回のhandshake retryを経て、
10:38:11にDrive distributionが再接続し、10:38:13にDrive probeが成功した。Driveのreadiness ACKは一時的に遅れ、10:39:03に
restart上限到達を記録した後、10:39:14からACKが継続した。一方、SensorsはModbus byte deliveryを再開したもののdistributionは再接続せず、
10:39:13にControllerのSensors recovery probeがtimeoutした。今回もA/B復帰だけによる2 linkの完全復旧には至らなかった。

追試後はDriveとControllerを通常firmwareへ戻した。Controller再起動後はDrive / Sensors両方のprobeが成功し、10:54:09に
3-step sensor-driven missionが完了した。Sensorsは再flashしていないためsample sequence 4–6から継続しており、final stateはfresh bootの
reference valueではなく、そのsampleに対応する`{x_mm: -100, y_mm: 0, heading_deg: 180}`だった。

## Breadboard parallel branchでの再試験

paired-wire配線を外し、breadboard railをcontinuous A/B trunkとして3台のtransceiverを短いbranchでparallel接続した。共通GNDも
breadboard railへ接続した。短いbench配線で外付け100 Ω / 120 Ω terminationは追加していない。HW-519上のtermination / bias抵抗は
個別測定していないため、この条件を一般的な終端構成として推奨するものではない。

左ControllerをRESETしたbaselineでは、Drive / Sensorsの両distribution connectionが再確立し、両probeと3-step missionが完了した。
その後Sensorsだけをannounce interval 10,000 ms、ACK timeout 45,000 ms、restart上限1回 / bootの試験firmwareへ変更した。
DriveとControllerは通常firmwareのままとした。切断前はSensorsの10秒heartbeatとDriveの30秒heartbeatが複数回ACKされた。

Sensors transceiverとbreadboard trunkを結ぶA/B branchだけを外し、continuous trunk、Controller / Drive branch、USB電源、共通GNDを
維持した。

- 12:57:59: Sensorsが最後のreadiness ACKを受信した
- 12:58:06: ControllerがUnit 2 timeoutを記録し、同時にUnit 1でも1回だけtimeoutした
- 12:58:20以降: Driveのreadiness heartbeat / ACKが継続した
- 12:58:48: Sensorsが`{:readiness_ack_timeout, 48760}`を検出し、distributionを1回再起動した
- 12:59:06: Controller側ではSensors connectionだけが`net_tick_timeout`で終了した
- 12:59:20: Sensorsのreadiness leaseだけが失効した
- Driveではcarrier session change、distribution disconnect、readiness lease失効を観測しなかった

切断操作直後のtransientはUnit 1にも1 transactionだけ影響したが、paired-wire試験と異なりDrive distributionは維持された。
これにより、continuous trunk / removable branch構成では単一peerの物理断を残るpeerから分離できることを確認した。

Sensors branchを同じ極性で戻すと、次の順に自動復旧した。

- 13:04:06: ControllerがSensorsのcarrier session changeを検出した
- 13:04:06–13:05:57: handshake retry中に`unexpected`、`unsupported_name`、timeoutを複数回記録した
- 13:05:59: ControllerがSensors distributionのreconnectを記録した
- 13:06:00: Sensorsが新しいconnectionのreadiness ACKを受信した
- 13:06:02: Sensorsへのrecovery probeが成功した
- 13:06:04: Driveへのprobeも成功し、`recovery complete restarted=sensors peer=drive`を記録した

carrier session changeからreconnectまで約113秒、両probe完了まで約118秒を要したが、Controller RESETなしで完全復旧した。
切断中に維持されたDrive connectionもrecovery probeに成功した。この時間は単一runの観測値で、復旧時間の上限ではない。

試験後はSensorsをremote health無効の通常firmwareへ戻した。`main.avm`は254,668 bytesだった。13:13:39以降の同時console監視では、
Driveの30秒heartbeat、Sensorsの30秒heartbeatと各ACKに対応する双方向byte deliveryが継続し、3台とも通常設定で動作していることを
確認した。

## 反復試験で判明したshared Clientのdeadline starvation

同じbreadboard branch試験を繰り返すと、最初の成功を再現できないrunがあった。ControllerでUnit別transaction traceを有効にしたrunでは、
Sensors branchを外した後の15:05:38からUnit 2だけでなくUnit 1も約2秒でtimeoutした。15:06:27にはDriveが`net_tick_timeout`となった。
一方、15:06:47からUnit 1は断続的に約320 msで成功し始め、branch復帰後はUnit 1 / 2とも約320 msへ戻った。

2個のvirtual UART adapterは1個のAVModbus managed Clientを共有していたが、各adapterは独立してpollをenqueueしていた。Clientはrequestを
直列に処理するものの、各requestのdeadlineにはmailbox内の待ち時間も含まれる。到達不能なUnit 2が2秒待つ間に、後続Unit 1のdeadlineも
ほぼ消費されるため、Unit 1はphysical送信を開始できても直後にtimeoutした。このhead-of-line deadline starvationが、正常なDriveまで
失う再現性のない結果を生んでいた。

対策として`DisterlProbe.PollScheduler`を追加し、Drive / Sensors adapterへ1個ずつpoll tokenをround-robinで渡した。adapterはtransactionの
成功または失敗後にtokenを返し、次のUnitはqueue待ちで消費されていない新しいdeadlineを得る。設計判断は
[ADR 0013](../adr/0013-schedule-shared-client-polls-round-robin.md)に記録した。

hostではtransport 67 tests、robot 61 testsが成功した。診断用Sensors firmwareはremote health有効、announce 10秒、ACK timeout 45秒、
restart上限1回 / boot、Controller firmwareはUnit別transaction trace有効としてflashした。書き込んだimage dataはSensors 257,816 bytes、
Controller 260,548 bytesだった。

## Round-robin schedulerでの再検証

branch切断前にControllerはDrive / Sensors両方へ接続し、両probeとsensor-driven missionを完了した。Unit 1 / 2のtransaction failureは0だった。

最初のscheduler runでは、Unit 2が2,002–2,010 msのtimeoutを繰り返す間も、Unit 1は約180–220 msで成功し続けた。Driveは30秒heartbeatを
継続し、Unit 1 failure、carrier session change、`net_tick_timeout`、readiness lease失効はいずれも0だった。Sensorsだけが
`net_tick_timeout`となった。これにより、round-robinがshared Clientのdeadline starvationを解消することを確認した。

このrunではSensorsをControllerより先にflashしたため、Controller起動待ちの間にboot単位のrestart上限1回を使用していた。branch復帰後、
Unit 2のphysical transactionは成功へ戻ったがdistributionは自動再接続しなかった。SensorsだけをRESETすると、Controllerは
carrier sessionを`986692637`から`1876068180`へ切り替え、15:41:03にSensors reconnect、15:41:07にSensors probe、15:41:09に
Drive probeと`recovery complete`を記録した。DriveはSensors RESET中も継続した。

restart budgetを未使用にした第2runでは次の順序になった。

- 15:43:12: Unit 2 timeoutを開始。Unit 1は約180–225 msの成功を継続
- 15:43:57: SensorsがACK欠落48,470 msを検出し、distributionを自動再起動
- Sensorsのcarrier sessionを`3269557313`、connection generationを`4063117390`へ更新
- 15:44:09: Controller側のSensors connectionだけが`net_tick_timeout`
- 15:44:23: Sensors readiness leaseだけが失効
- branch復帰後: handshake中に`unexpected`、`invalid_challenge`、`no_link_manager_response`を記録してretry
- 15:49:46: ControllerがSensors reconnectを記録
- 15:49:50: Sensors probe成功
- 15:49:52: Drive probe成功、`recovery complete restarted=sensors peer=drive`

第2runもController RESETとSensors RESETを行わずに完全復旧した。branchを戻すまで利用者操作の待ち時間が含まれるため、切断時間や
restartからreconnectまでの全経過時間をtransport性能値として扱わない。物理復帰後も複数回のhandshake retryを要しており、setup retryの
改善余地は残る。

## 反復試験の結果

| 確認項目 | 結果 |
| --- | --- |
| 到達不能なUnit 2のtimeout | 約2秒 / turnで継続 |
| 同時期のUnit 1 transaction | 約180–225 msで成功、failure 0 |
| Sensors切断中のDrive distribution | 2 runで継続 |
| remote healthの自動restart | 未使用budgetのrunで48,470 ms後に成功 |
| branch復帰後のphysical Unit 2 | 成功 |
| 手動resetなしのSensors再接続 | 第2runで成功 |
| 復旧後のSensors / Drive probe | 両方成功 |
| handshake retry error | 残存。最終的には自動収束 |

反復試験後は3 roleを診断設定なしでrebuild / flashした。通常image dataはDrive 257,844 bytes、Sensors 257,816 bytes、Controller
260,548 bytesだった。ControllerはDrive、Sensorsの順に接続し、両probeを完了した。15:57:31に3-step sensor-driven missionが
`{x_mm: 200, y_mm: 0, heading_deg: 90}`で完了し、その後もDrive / Sensorsの30秒heartbeatとACKが継続した。

## 結論

物理的な双方向断でもconnection ID付きreadiness ACKは障害を検出し、remote restart回数をboundedに保った。paired-wire配線では
removable nodeの端子がbus経路または電気条件に関与し、中央と右端のどちらを外しても残るpeerを維持できなかった。breadboard上で
continuous trunkとnode別branchを作ると、Sensors branch切断中もDrive distributionを維持できた。

branch復帰後にはSensors handshakeがretryしたものの、Controller RESETなしでSensors reconnectと両peerのprobeまで完了した。
一方、paired-wire試験のようにbus全体へ影響した場合はlink復帰だけで全streamが再同期せず、Controller RESETを要した。したがって
自動復旧の成功条件には物理的なfailure isolationが含まれる。独立timerでpollする実装は反復試験で正常peerのdeadlineも失わせたが、
round-robin scheduler導入後は2回のbranch切断中にDriveを維持した。長い配線、復旧時間の上限、termination / bias、抜き差しtransientは
未評価である。

health timeoutは固定45秒を推奨値に昇格せず、負荷profile、announce interval、最大queue遅延に対する余裕を測定して決める。次は同じ
branch断を複数回反復し、復旧時間、queue / memoryのsettling、Drive側のtransient timeoutを測定する。
