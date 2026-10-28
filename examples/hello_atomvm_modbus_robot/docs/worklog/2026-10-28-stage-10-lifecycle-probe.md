# Stage 10 lifecycle probe観測基盤

## 目的

長時間通信断で観測した`net_kernel_stop_timeout`を、remote healthやapplication trafficに依存せず再現する準備を行う。

## 実装

- `RobotSim.NetKernelLifecycle`へstop、登録解除待ち、startを分離した
- callback注入により、停止API失敗、登録解除timeout、再開失敗をhostで個別再現できるようにした
- `ROBOT_MULTINODE_LIFECYCLE_PROBE_AFTER_MS`でremote bootごとに1回だけrestartを発火できるようにした
- lifecycle eventへ`process_count`とowner processの`message_queue_len`を追加した
- 全processのmailbox走査は計測負荷を避けるため実装していない

## Host検証

`mise exec -- mix test`は142 tests、0 failuresだった。Controller、Drive、Sensorsの`mix atomvm.check`も成功した。

## 実機準備

Sensors用に60秒後のprobe、10秒間隔のresource metrics、connection traceを有効にしたPackBEAMを生成した。
サイズは293,200 bytesで、Sensorsへのflashとhash verificationに成功した。Initial recovery、remote health、response faultは無効とした。

実機条件と判定項目は[Stage 10試験計画](../stage-10-net-kernel-lifecycle.md)を正とする。

## Healthy stop / start

3台をclean bootし、Sensorsのbootから60秒後にprobeを発火した。

| Event | Sensors `at_ms` | Resource |
| --- | ---: | --- |
| `restart_started` | 60,413 | free 89,376 bytes、20 processes、mailbox 0 |
| `kernel_stop_requested` | 60,437 | free 88,588 bytes、20 processes、mailbox 0 |
| `kernel_stop_completed` | 60,525 | free 100,680 bytes、9 processes、mailbox 0 |
| `kernel_start_started` | 60,541 | free 100,680 bytes、9 processes、mailbox 0 |
| `kernel_start_succeeded` | 60,641 | free 90,636 bytes、19 processes、mailbox 1 |
| `readiness_acknowledged` | 67,990 | free 86,208 bytes、21 processes、mailbox 0 |

登録解除は88 ms、stop要求からstart成功までは204 msだった。Controllerは新connection `2059809243`へ再接続し、
`recovery_verified`とDriveの`peer_maintained`を記録した。ControllerのSensors transaction failureは1件増えたが、Drive failureは
増えなかった。Sensorsのprocess数は安定後19へ戻った。

## Branch切断中のprobe

Sensorsだけをresetし、readiness ACK後、60秒のprobeより前にSensors branchを切断した。

| Event | Sensors `at_ms` | Resource |
| --- | ---: | --- |
| `restart_started` | 60,413 | free 89,488 bytes、20 processes、mailbox 0 |
| `kernel_stop_requested` | 60,437 | free 88,720 bytes、20 processes、mailbox 0 |
| `kernel_stop_completed` | 60,504 | free 100,836 bytes、9 processes、mailbox 0 |
| `kernel_start_started` | 60,521 | free 100,836 bytes、9 processes、mailbox 0 |
| `kernel_start_succeeded` | 60,620 | free 90,828 bytes、19 processes、mailbox 1 |
| `initial_connection_timeout` | 68,711 | free 89,968 bytes、18 processes、mailbox 0 |

この条件ではstopは67 msで完了し、`net_kernel_stop_timeout`を再現しなかった。`net_kernel.start/2`も成功を返したが、
`dist_util`はsetup timer timeoutでconnectionを終了した。したがって`kernel_start_succeeded`と`restart_succeeded`は
distribution handshakeやController再接続の成功を表さない。

Branch切断中、Sensorsのprocess数は17前後、owner mailboxは0のまま、free heapは約90 KiBから約82 KiBへ低下した。Branch復帰後は
FC-100 transactionが再開したが、小さい空exchangeだけが継続し、distributionは再接続しなかった。観測したminimum free heapは
45,308 bytesだった。Process数とowner mailboxだけでは、この低下を説明できない。

ControllerのSensors transactionは150件連続で失敗した後に成功へ戻った。Driveのtransaction failureは増えず、readiness ACKも
継続した。Sensors reset後はfresh heap約107 KiBで起動し、Controllerへ再接続した。

このrunは、過去のstop failureではなく、stop成功後のsetup failureとresource低下を再現した。Heap低下の原因は、
distribution setup、終了後に残るprocess / timer、carrier stateのどこにあるか未特定である。

## 復旧

試験後、probe、trace、periodic metricsを無効にした通常Sensors firmwareへ戻した。PackBEAMは292,516 bytesで、flashと
hash verificationに成功した。
