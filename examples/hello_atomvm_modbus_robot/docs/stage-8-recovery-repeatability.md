# Stage 8 recovery policy反復試験

状態: 完了（2026-10-26）

## 目的

Current policyとdeferred policyを同じ3台構成、event schema、resource項目で反復し、成功率、復旧時間、失敗位置を比較する。
単発の成功を一般的な保証へ拡張せず、各runをclean bootと独立したlog windowで評価する。

## 試験matrix

Sensors branchだけを切断し、Drive branchとcontinuous A/B trunkは維持する。各条件を2回実行する。

| Policy | 目標切断時間 | Runs |
| --- | ---: | ---: |
| Current | 120秒 | 2 |
| Current | 300秒 | 2 |
| Deferred | 120秒 | 2 |
| Deferred | 300秒 | 2 |

操作応答時刻は厳密な電気的切断時間ではない。Remoteが`transport_resumed`を記録した場合は`transport_gap_ms`を優先し、記録できない
failureではbranch取り外し・復元のhost時刻を使用する。

## Firmware profile

3 roleで次を共通にする。

```text
ROBOT_MODE=multinode
ATOMVM_UART_SPEED=115200
ROBOT_MULTINODE_CONNECTION_TRACE=true
ROBOT_MULTINODE_TRANSPORT_ACTIVITY_TRACE=true
ROBOT_MULTINODE_REMOTE_HEALTH_ENABLED=true
ROBOT_MULTINODE_REMOTE_HEALTH_TRACE=true
ROBOT_MULTINODE_METRICS_INTERVAL_MS=10000
ROBOT_MULTINODE_REMOTE_ACK_TIMEOUT_MS=90000
ROBOT_MULTINODE_REMOTE_MAX_RESTARTS=1
ROBOT_MULTINODE_TRANSPORT_READY_CONFIRMATIONS=2
```

Currentは`ROBOT_MULTINODE_DEFER_RESTART_UNTIL_TRANSPORT_READY=false`、deferredは`true`とする。Controllerのapplication behaviorは
両profileで同じにする。Fault injectionとconcurrent trafficは無効にする。

## 1 runの手順

1. 3台をresetし、対象bootのlogを開始する。
2. Drive / Sensorsのreadiness ACK、adaptive mission完了、queue drainを確認する。
3. Sensorsのrestart budgetが未使用であることを確認する。
4. Sensors branchを外し、host時刻を記録する。
5. 120秒または300秒を経過してからbranchを復元し、host時刻を記録する。
6. 最大90秒、または明示的failureまでreconnectとprobeを観測する。
7. 3 role logを保存し、`--mode recovery`とrun固有の`--since` / `--until`で集計する。
8. 次のrun前に3台をresetし、restart budgetとconnection IDを持ち越さない。

Log名は`modbus-stage8-<policy>-<duration>s-r<run>-<role>.log`とする。

## 共通測定項目

- recovery判定、failure event、restart budget exhaustion
- branch操作時刻、FC-100 exchange gap
- transport ready → restart started
- transport ready → recovery verified
- restart started → restart succeeded
- restart succeeded → remote reconnected
- Drive connection IDと`peer_maintained`
- Unit 1 / Unit 2 transaction failure増分
- global queue high-water、drain、rejection
- Controller / Drive / Sensorsのminimum free heap

## 成功条件

- `evaluation.recovery == :passed`かつ`successful == true`
- `recovery_verified`と`peer_maintained`を記録する
- kernel stop / start、restart、budget exhaustionのfailure eventが0
- Drive connectionを維持する
- queueが0へdrainし、global rejectionが0

Current policyが失敗するrunも、有効な比較結果としてfailure位置とresourceを記録する。Remote process停止後にtransport eventを
処理できない場合、復旧時間は`nil`のままにし、推定値で補完しない。

## 判定方法

8 runsの成功率、復旧時間、failure位置、memory推移を比較してから、deferred policyを既定値にするかopt-inのまま維持するか判断する。
2 runs / conditionはexploratory sampleであり、production reliabilityを示さない。

## 結果

| Policy | 目標切断時間 | 成功 | 観測したFC-100 gap |
| --- | ---: | ---: | --- |
| Current | 120秒 | 0 / 2 | 未観測、112.950秒 |
| Current | 300秒 | 0 / 2 | 289.082秒、248.129秒 |
| Deferred | 120秒 | 2 / 2 | 166.510秒、239.372秒 |
| Deferred | 300秒 | 2 / 2 | 393.908秒、337.038秒 |

Current policyは4回ともphysical transport復帰前にrestartを開始し、1回のbudgetを消費した。復線後にFC-100 exchangeを
観測できたrunでもdistributionは再接続しなかった。Deferred policyは4回ともtransport復帰後33–34 msでrestartを開始し、
10.690–12.119秒でSensorsのrecovery probeとDriveの維持確認まで完了した。global queue rejectionとrestart budget exhaustionは
0件だった。

目標切断時間はoperator向けの条件名であり、実測時間ではない。表のgapはremote adapterが観測した値で、adapter再生成前の区間を
含まない場合がある。Current 120秒の1回目はobserver eventを記録できなかったため、推定値を補っていない。

## 採用判断

`ROBOT_MULTINODE_DEFER_RESTART_UNTIL_TRANSPORT_READY`は既定の`false`を維持する。今回の4 / 4成功は物理branch切断に対する
有力な結果だが、requestを受信し続ける非対称response blackoutではtransport gapを検出できない。Stage 9でfailure modelを広げるまで、
1 connectionだけを持つremote向けのopt-in実験機能として扱う。判断は
[ADR 0027](adr/0027-keep-deferred-restart-opt-in.md)、個別の測定値は
[作業記録](worklog/2026-10-26-stage-8-recovery-repeatability.md)を参照する。
