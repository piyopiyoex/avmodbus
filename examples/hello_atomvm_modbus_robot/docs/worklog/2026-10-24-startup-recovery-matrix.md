# 起動・復旧test matrixのhost・3台実機baseline — 2026-10-24

## 目的

接続復旧codeを変更する前に、3台構成の起動順序、初回handshake failure、接続後障害を同じeventと完了条件で
比較できるようにする。

## 実装

- `RobotSim.ConnectionTrace`にopt-inのconnection lifecycle logを追加した
- `RobotSim.StartupRecoveryMatrix`に10 scenarioを定義した
- 混在console logからtrace行だけを抽出して評価できるようにした
- firmwareへ含めないhost model、script、focused testを追加した

matrixの内訳は次のとおりです。

| 分類 | 件数 |
| --- | ---: |
| 起動順序の全順列 | 6 |
| 初回handshake failure | 2 |
| 接続後障害 | 2 |

## Host検証

```sh
cd examples/hello_atomvm_modbus_robot
mise exec -- mix test test/connection_trace_test.exs test/startup_recovery_matrix_test.exs
mise exec -- mix run scripts/startup_recovery_matrix.exs
```

focused testは18件すべて成功した。matrix scriptは10 scenarioを安定した順序で出力した。

host testでは次を確認した。

- 全証跡が揃った起動runを`:passed`とする
- 指定と異なる起動順序を`:incomplete`として残す
- 初回setup failureだけで停止したrunを`:runtime_blocker`とする
- failure後に両remoteが接続したrunを`:recovered_after_failure`とする
- 接続後障害では正常peerの`peer_maintained`証跡を必須にする
- restart failureをblockerとして残す
- 通常logを無視し、connection traceだけをparseする

## AtomVM buildと回帰確認

最初の`mix atomvm.check`では、`ConnectionTrace`に置いたlog parserがAtomVM未対応の
`Regex.run/2`、`Integer.parse/1`、`String.trim/1`を参照すると警告された。parserは実機では使わないため、
`host/startup_recovery_matrix.ex`へ移し、firmware側には整形と出力だけを残した。

分離後の結果は次のとおり。

| 対象 | 結果 |
| --- | --- |
| repository本体 | 228 tests、0 failures |
| `hello_atomvm_modbus_disterl` | 68 tests、0 failures |
| `hello_atomvm_modbus_robot` | 106 tests、0 failures |
| Controller / Drive / Sensors | trace有効時の`mix atomvm.check`にwarningなし |
| Controller / Drive / Sensors | trace有効時の`mix atomvm.packbeam`に成功 |

## 3台実機baseline

AtomVM `release-0.7` `18b35870` + local patch `a1069573`（起動時revision
`0.7.0-beta.1+git.a1069573`）と、次のUSB serial対応で確認した。

| Role | USB serial | 観測時のport |
| --- | --- | --- |
| Controller | `38:44:BE:A5:05:14` | `/dev/ttyACM2` |
| Drive | `38:44:BE:A5:04:DC` | `/dev/ttyACM1` |
| Sensors | `10:BD:A3:CF:09:04` | `/dev/ttyACM0` |

3 roleの全起動順序を約1秒間隔でresetした。全6 runで両FC-100 peerの準備、3 roleのdistribution起動、
両remoteのreadiness ACK、Controller側の2接続が成立し、`initial_connection_timeout`は発生しなかった。

| 起動順序 | Drive `remote_connected` | Sensors `remote_connected` | 結果 |
| --- | ---: | ---: | --- |
| Controller → Drive → Sensors | 6,118 ms | 6,914 ms | passed |
| Controller → Sensors → Drive | 7,135 ms | 6,883 ms | passed |
| Drive → Controller → Sensors | 6,020 ms | 6,275 ms | passed |
| Drive → Sensors → Controller | 4,520 ms | 4,778 ms | passed |
| Sensors → Controller → Drive | 6,032 ms | 5,780 ms | passed |
| Sensors → Drive → Controller | 4,549 ms | 4,807 ms | passed |

時刻は各runのController monotonic clockであり、role間のclock差は含めない。最初のrunでは両probeと
sensor-driven mission完了まで確認した。他の5 runは接続matrixの完了条件を満たした時点で15秒の採取を終了した。

## 実機で見つかった初回handshakeの境界

ControllerをROM bootloaderで停止し、Driveだけを起動した。`net_kernel.start/2`は約375 msで成功を返し、
その後に`dist_util` setupが`timer_timeout`で終了した。したがって、初回handshake failureは
`distribution_start_failed`では観測できない。

connection policyを変えずにこの非同期な境界を記録するため、初回readiness ACK待ちが8秒を超えた場合の
`initial_connection_timeout`をtraceに追加した。8秒はAtomVMの7秒timerを変更する値ではなく、実機logに表れる
setup failureの直後を記録する観測期限である。

Driveでは`initial_connection_timeout`後にControllerを起動しても60秒以内に自動復旧しなかった。Controllerは
Sensorsと接続したままで、Drive linkには`unexpected`、`unsupported_name`、`timer_timeout`を観測した。
Driveだけをresetすると、約5.2秒後にreadiness ACKを受け取り、Controllerは両remoteのprobeとmissionを完了した。

このrunでは全board resetは不要だったが、Driveの自動復旧に成功したわけではない。matrix reportに
`fault_role_restarted`を追加し、failure後の接続成功と対象board resetの有無を分けて記録する。

Sensorsでも同じ手順を実行した。`initial_connection_timeout`は8,429 msで記録され、後からControllerと
Driveを起動しても60秒以内にSensorsは自動復旧しなかった。Driveは接続とreadiness ACKを維持した。
Sensorsだけをresetすると約5.9秒後にACKを受け取り、Controllerは両probeとmissionを完了した。

| Scenario | 対象peerの同一boot内復旧 | 正常peer | 対象peerだけのreset後 |
| --- | --- | --- | --- |
| Drive-first timeout | 60秒以内に復旧せず | Sensors維持 | Drive ACK約5.2秒、両probe成功 |
| Sensors-first timeout | 60秒以内に復旧せず | Drive維持 | Sensors ACK約5.9秒、両probe成功 |

この対称的な結果から、対象role固有のapplication処理ではなく、先行した`serial_dist`の片側stateが
後発Controllerとの新しいsetupを妨げる共通の境界と判断する。PR 2では、runtimeの7秒timerを延長するのではなく、
example側が初回readiness timeout後に対象remoteのdistributionをbounded restartできるかを最小修正として検討する。

## 境界

host modelはscenario coverageと判定logicを検証するもので、AtomVM setup、UART、RS485、実memoryの代替ではない。
実機では6起動順序と2初回failureを確認したが、新しいtraceを用いた接続確立後の長時間切断はまだ実施していない。
connection timeout、restart policy、FC-100 wire protocolは変更していない。

次は後続PRで初回readiness timeout後のbounded remote restartを設計し、このbaselineと比較する。
