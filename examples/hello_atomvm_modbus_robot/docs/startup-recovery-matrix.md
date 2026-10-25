# 起動・復旧test matrix

既存の接続管理を変更する前に、3台構成の初期化・再接続failureを同じ条件とevent名で反復するための計画です。
この段階ではtimeout延長や新しい復旧policyを追加せず、観測可能性と判定基準を整えます。

## Scenario

host matrixは次の10 scenarioを定義します。

| 分類 | 件数 | 内容 |
| --- | ---: | --- |
| 起動順序 | 6 | Controller、Drive、Sensorsの全順列 |
| 初回handshake failure | 2 | DriveまたはSensorsのsetup failure |
| 接続後障害 | 2 | DriveまたはSensorsのstale検出、restart、再接続 |

起動順序は最初のroleだけでなく全順列を残し、同じ「Controller-first」でも後続remoteの順番による差を区別します。
接続後障害では、復旧対象の疎通に加えて、正常peerのconnection identityとprobe成功を別の証跡として要求します。

## 判定

`RobotSim.StartupRecoveryMatrix`は観測eventを次へ分類します。

| 結果 | 意味 |
| --- | --- |
| `:passed` | 必要なeventと順序が揃った |
| `:recovered_after_failure` | failureを観測した後、必要な接続と疎通がすべて成立した |
| `:runtime_blocker` | setup、restart、recovery verificationの明示的なfailureで停止した |
| `:incomplete` | 必要なeventが不足した、または順序がscenarioと一致しない |

`runtime_blocker`は自動的にAtomVMの問題を意味しません。carrier、example lifecycle、runtimeのどこで停止したかを
eventと元のconsole logから切り分けます。
`fault_role_restarted`はblocker後に対象roleの`role_started`を再び観測したかを示します。
`:recovered_after_failure`だけで同一board boot内の自動復旧と判断しません。

## Connection trace

`ROBOT_MULTINODE_CONNECTION_TRACE=true`をbuild時に指定すると、既存の接続動作を変えず、次の形式を追加で出力します。

```text
modbus_robot_connection: at_ms=12345 event=remote_reconnected role=sensors boot_id=100 connection_id=200
```

主なeventは次のとおりです。

- `role_started`
- `carrier_wait_started` / `carrier_peer_ready`
- `distribution_start_started` / `distribution_start_succeeded` / `distribution_start_failed`
- `readiness_wait_started` / `initial_connection_timeout` / `readiness_acknowledged`
- `remote_connected` / `remote_reconnected`
- `stale_detected`
- `restart_started` / `restart_succeeded` / `restart_failed` / `restart_budget_exhausted`
- `recovery_verified` / `recovery_verification_failed` / `peer_maintained`

`at_ms`は各boardのmonotonic clockであり、board間で値を直接比較しません。複数consoleを統合するときはhost側の受信順を保持し、
起動操作と物理切断の時刻も別途記録します。

## Hostでの確認

```sh
cd examples/hello_atomvm_modbus_robot
mise exec -- mix test test/connection_trace_test.exs test/startup_recovery_matrix_test.exs
mise exec -- mix run scripts/startup_recovery_matrix.exs
```

統合済みlogを評価する場合はscenario IDとfileを指定します。

```sh
mise exec -- mix run scripts/startup_recovery_matrix.exs \
  startup_controller_drive_sensors combined.log
```

終了code `0`は`:passed`または`:recovered_after_failure`、`2`はblockerまたは証跡不足です。

## 実機手順

1. 3 roleを`ROBOT_MULTINODE_CONNECTION_TRACE=true`でbuildする。
2. 初回起動matrixではremote healthを無効のままにし、指定順で3台を起動する。
3. 初回handshake failureでは対象remoteを先行起動し、AtomVMの7秒setup failureと、8秒後も
   readiness ACK待ちであることを`initial_connection_timeout`として記録する。
4. 接続後障害では通常接続を確認してから対象branchを切断し、stale検出とremote-side restartを記録する。
5. 復旧対象と正常peerのprobe結果、boot ID、connection IDを記録する。
6. 全board resetが必要だった場合は自動復旧成功として扱わず、停止eventと手動操作をworklogへ残す。

初回failure後のautomatic recoveryは、`initial_connection_timeout` → `restart_started` →
`restart_succeeded` → `remote_connected`の順を必須とします。対象boardのresetだけで復旧したrunは
`fault_role_restarted=true`とし、automatic recoveryに含めません。

接続後障害でautomatic restartを評価する場合だけ、対象remoteに既存の
`ROBOT_MULTINODE_REMOTE_HEALTH_ENABLED=true`を設定します。`ROBOT_MULTINODE_REMOTE_ACK_TIMEOUT_MS`は既存の
ACK間隔実測より十分大きくし、このmatrixのために7秒setup timerを変更しません。

## 境界

- host matrixはUART timing、RS485 electrical behavior、AtomVM heapをsimulationしない
- traceはconnection lifecycleを変更しない
- 初回復旧はrestart上限を消費し、同じboard boot内では補充しない
- 実機結果を得る前にexample側またはAtomVM側の原因と断定しない
