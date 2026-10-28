# Stage 10 `net_kernel` lifecycle最小再現

状態: 実機試験中

## 目的

`net_kernel`のsetup failureとstop failureをrobot missionやremote health timeoutから分離して再現する。
停止要求、登録解除待ち、再開、distribution再接続を別々に記録し、example側で改善できる範囲とAtomVM runtimeの制約を整理する。

## 観測境界

`RobotSim.NetKernelLifecycle`は次の境界だけを担当する。

1. `net_kernel.stop/0`を呼び出す
2. `:net_kernel`の登録解除をbounded pollする
3. 同じroleとtransport設定で`net_kernel.start/2`を呼び出す

Application probe、remote health budget、再接続確認は呼び出し側の責任とする。Host testではcallbackを差し替え、停止API失敗、
登録解除timeout、再開失敗を個別に再現する。

実機のlifecycle eventにはESP heapに加え、VM全体の`process_count`とlifecycle ownerの`owner_message_queue_len`を付ける。
全processのmailbox合計は、走査による計測負荷を避けるため取得しない。

## 実機profile

最初のbaselineではSensorsだけにone-shot probeを設定する。

```text
ROBOT_MODE=multinode
ROBOT_ROLE=sensors
ATOMVM_UART_SPEED=115200
ROBOT_MULTINODE_CONNECTION_TRACE=true
ROBOT_MULTINODE_METRICS_INTERVAL_MS=10000
ROBOT_MULTINODE_INITIAL_RECOVERY_ENABLED=false
ROBOT_MULTINODE_REMOTE_HEALTH_ENABLED=false
ROBOT_MULTINODE_LIFECYCLE_PROBE_AFTER_MS=60000
MODBUS_FAULT_DROP_RESPONSES=0
```

`ROBOT_MULTINODE_LIFECYCLE_PROBE_AFTER_MS=0`はprobeを無効にする。正の値を指定したremoteはbootから指定時間後に1回だけ
distributionをstop / startする。Restart budgetは消費しない。

## 試験matrix

| Scenario | 操作 | 確認項目 |
| --- | --- | --- |
| Healthy stop / start | 3台接続を維持したままprobeを発火 | stop完了、start成功、再接続、Drive維持 |
| Setup failure | Controller不在でremoteを起動 | `distribution_start_failed`または初回接続timeoutを分離 |
| Stop failure | Sensors branchをprobe前に切断 | stop API返却、登録解除timeout、heap / process / mailbox |
| Recovery after stop failure | branchを復帰 | 自動復旧の有無と必要なmanual resetを記録 |

各scenarioはclean bootから実行する。最初にhealthy baselineを確立し、失敗を再現するまではpoll回数やtimeoutを変更しない。

## 途中結果

Healthy stop / startでは、Sensorsの登録解除を88 ms、再開までを合計204 msで完了し、Controller再接続とDrive維持を確認した。

Sensors branchをprobe前に切断した試験でもstopは67 msで完了したため、過去の`net_kernel_stop_timeout`は再現しなかった。一方、
`net_kernel.start/2`の返却後にdistribution setupがtimeoutし、branch復帰後はphysical FC-100 pollingだけが再開した。
Distributionは自動復旧せず、Sensors resetが必要だった。詳細は
[Stage 10実機baseline](worklog/2026-10-28-stage-10-lifecycle-probe.md)を参照する。

## 完了条件

- setup failureとstop failureを異なるevent列として記録できる
- healthy stop / startが再接続まで完了するか、具体的な停止境界を特定できる
- stop failure前後のheap、process数、owner mailboxを比較できる
- example側のlifecycle管理とAtomVM runtimeの責任範囲を文書化できる

AtomVM upstreamへのIssue / PRは作成せず、対象v0.7 snapshotでの結果をこのrepositoryに記録する。
