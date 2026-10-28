# Stage 11 application recovery統合検証

## 目的

Distribution接続の復旧後にapplicationが安全な状態を確認できるか、mission自動再開を導入せず検証する。

## 実装

- Mission failureを`aborted / stop`と`indeterminate / snapshot`へ分類した
- Sensors再接続後にだけ有効化できるapplication recovery probeを追加した
- Probeはfresh sensor sampleをDriveへrelayし、現在のDrive boot IDでguardした`:status`を読む
- Movement commandとmission resumeは実行しない
- Controller health loopを塞がないよう、probeを別processで実行する
- 物理切断の操作窓を固定するため、通常は0 msのstep間隔を実機profileだけ120,000 msに設定できるようにした

既定値は無効であり、`ROBOT_MULTINODE_APPLICATION_RECOVERY_PROBE_ENABLED=true`でControllerだけに有効化する。

## Host検証

`mise exec -- mix test`は148 tests、0 failuresだった。次を確認した。

- Sensor timeoutを明示的なmission abortへ分類する
- Drive boot変更をindeterminate outcomeへ分類する
- Fresh sampleをrelayした後もrover positionが変化しない
- Sensor replyがない場合にbounded timeoutを返す
- Step間隔は完了したstep間だけに適用し、最後のstep後には待たない

Controller、Drive、Sensorsの`mix atomvm.check`も成功した。実機条件と判定項目は
[Stage 11試験計画](../stage-11-application-recovery.md)を正とする。

## 実機結果

3台のXIAO ESP32-C5と共有RS485 busを使い、次のController診断profileで試験した。

- `ROBOT_MULTINODE_APPLICATION_RECOVERY_PROBE_ENABLED=true`
- `ROBOT_COMMAND_TIMEOUT_MS=30000`
- `ROBOT_COMMAND_RETRIES=0`
- `ROBOT_SENSOR_MISSION_STEPS=6`
- `ROBOT_SENSOR_MISSION_STEP_DELAY_MS=120000`
- `ROBOT_MULTINODE_LEASE_MS=60000`

Sensorsはdeferred restart、45秒remote ACK timeout、connection trace、10秒memory metricsを有効にした。AtomVMは
release-0.7 snapshot `18b35870`とlocal compatibility patch `a1069573`からbuildした既存baselineを使用した。

### Mission中断

Clean boot後、step 1はsample sequence 1を使って100 mm前進し、Drive stateは
`x=100 mm, y=0 mm, heading=0°`になった。次のstepまでの待機中にSensors branchを切断した。

Sensorsは48,449 msのACK gapで`restart_deferred`を記録した。ControllerではSensorsのreadiness lease expiryと
`net_tick_timeout`を確認した一方、Driveのtransaction failureは2のまま増えなかった。Step 2のsensor requestは30秒でtimeoutし、
次を記録した。

```text
modbus_robot_multinode: sensor mission stopped reason={:sensor_mission_failed, 2, :sensor_timeout}
modbus_robot_application_recovery: outcome=aborted action=stop step=2 reason=:sensor_timeout
```

この時点でstep 2のmovement commandは送信されていない。

### Transportとdistributionの復旧

Branch復帰後、Sensorsは219,350 msのFC-100 exchange gapを記録した。565 ms後の2回目の有効exchangeで
`transport_ready`となり、Controller側のSensors queueは最終的に0まで排出された。Drive connectionは維持した。

復旧直後の大量のmetricsでapplication probeの結果行を保存できなかったため、Sensorsだけをresetし、同じ停止済みmissionに対する
再接続結果を短い間隔で採取した。Sensorsは新しいboot ID `719161654`、connection ID `3961218437`でreadiness ACKを受けた。
ControllerはSensors再接続後にSensors / Drive両probeを完了し、Driveを維持したままapplication recovery probeを開始した。

```text
modbus_robot_application_recovery: probe=verified boot_id=3682071001 \
  sample=%{sequence: 2, distance_mm: 450, battery_percent: 99} \
  state=%{x_mm: 100, y_mm: 0, heading_deg: 0, ...}
```

Fresh sample取得、Driveへのrelay、boot IDでguardした`:status`が成功した。Drive stateはstep 1直後から変わらず、missionの自動再開と
step 2の重複実行はなかった。

### Resource snapshot

Probe完了後は両peerのqueueとglobal queueが0 bytes / 0 chunksへ戻り、global rejectionは0だった。観測high-waterは783 bytes /
12 chunks、Controller minimum free heapは66,464 bytesだった。Remote側minimum free heapはSensors 81,636 bytes、Drive
79,660 bytesだった。最終transaction failureはDrive 2、Sensors 98で、Sensorsの値にはbranch切断とboard resetを含む。

## 結論

対象scenarioでは、missionを明示的に中断し、正常なDrive connectionを保ったままSensorsを復旧できた。復旧後のprobeは現在stateを
読み取るだけで、movementやmission resumeを行わない。これによりStage 11を完了とする。

この結果は単一runの探索的baselineである。Durable state、未確定movementの自動照合、mission自動再開、任意の障害時間での復旧は
保証しない。
