# 初回接続timeout後のbounded recovery — 2026-10-24

## 目的

起動・復旧matrixで再現したremote-firstの片側`serial_dist` stateを、board resetなしで解消する。
AtomVMの7秒setup timerは変更せず、example側のremote distribution restartだけを対象とする。

## 実装

- 初回readiness ACK待ち8秒で`initial_connection_timeout`を記録する
- 既存の`restart_remote_distribution/6`でremoteの`net_kernel`をstop / startする
- `RemoteHealth.request_restart/2`で初回復旧と接続後healthのboot単位budgetを共用する
- budget消費後は`restart_budget_exhausted`を記録する
- `ROBOT_MULTINODE_INITIAL_RECOVERY_ENABLED=true`を既定値とする

## 実機構成

- AtomVM `release-0.7` `18b35870` + local patch `a1069573`
- 3 × Seeed Studio XIAO ESP32-C5
- breadboard上のcontinuous A/B trunkとrole別branch
- 115,200 baud、FC-100、restart上限1回 / board boot

## Drive-first

ControllerとSensorsをROM bootloaderで停止し、Driveを先行起動した。Driveの最初のboot IDは
`4255382260`で、connection IDは`537997897`だった。

| Event | Drive monotonic time |
| --- | ---: |
| `initial_connection_timeout` | 8,433 ms |
| `restart_started` | 8,451 ms |
| `restart_succeeded` | 8,601 ms |
| 2回目の`initial_connection_timeout` | 16,637 ms |
| `restart_budget_exhausted` | 16,655 ms |
| `readiness_acknowledged` | 16,929 ms |

restart後のconnection IDは`3608575643`で、boot IDは変化しなかった。2回目の観測期限はACKの約274 ms前に
発生したが、restart上限1回を消費済みのため進行中handshakeを再度切断せず、そのまま接続した。
ControllerはDrive / Sensorsの両方に接続し、両probeとsensor-driven missionを完了した。

## Sensors-first

ControllerとDriveを停止し、Sensorsを先行起動した。Sensorsのboot IDは`2179631455`のまま、
connection IDは`1061377841`から`4153808991`へ変化した。

| Event | Sensors monotonic time |
| --- | ---: |
| `initial_connection_timeout` | 8,429 ms |
| `restart_started` | 8,448 ms |
| `restart_succeeded` | 8,598 ms |
| `readiness_acknowledged` | 15,446 ms |

2回目の8秒期限前にACKを受け取った。Controllerは両remoteに接続し、両probeとmissionを完了した。

## 結論

初回setup timeout後のbounded remote restartは、Drive / Sensorsの両方をboard resetなしで同一boot内復旧させた。
PR 1では同じscenarioが60秒以内に復旧しなかったため、対象としたblockerに対する改善を確認できた。

一方、Drive runは接続直前に2回目の観測期限へ到達した。restart上限を増やすことは復旧性の単純な改善ではなく、
遅いが進行中のhandshakeを壊す可能性がある。上限1回を実機baselineとし、長時間通信断とのbudget共用は後続実験で扱う。
後続結果は[接続復旧とリソース管理の実験結果](../reliability-backlog.md)に集約した。

## 検証

| 対象 | 結果 |
| --- | --- |
| repository本体 | 228 tests、0 failures |
| `hello_atomvm_modbus_disterl` | 68 tests、0 failures |
| `hello_atomvm_modbus_robot` | 107 tests、0 failures |
| Controller / Drive / Sensors | 復旧有効で`mix atomvm.check`にwarningなし |
| Drive | `ROBOT_MULTINODE_INITIAL_RECOVERY_ENABLED=false`で`mix atomvm.check`にwarningなし |
| Controller / Drive / Sensors | 復旧有効でPackBEAM生成とflashに成功 |
