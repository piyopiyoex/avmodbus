# Stage 7長時間通信断復旧の計測基盤

## 目的

約180秒のSensors branch切断後に、physical pollingが復帰してもdistributionが再接続せずfree heapが低下した処理範囲を
切り分ける。restart policyやtimeoutを変更する前に、`net_kernel` lifecycleとdistribution recoveryを別eventとして記録する。

## 変更

既存の`restart_started`、`restart_succeeded`、`remote_reconnected`、`recovery_verified`に加えて、次のeventを追加した。

- `kernel_stop_requested`
- `kernel_stop_completed`
- `kernel_stop_failed`
- `kernel_start_started`
- `kernel_start_succeeded`
- `kernel_start_failed`

connection traceを有効にしたAtomVM実機では、restart、kernel stop / start、readiness timeout / ACK、restart budget拒否のeventへ
取得時点の`free_heap_bytes`、`largest_free_block_bytes`、`minimum_free_heap_bytes`を付ける。trace無効時はmemory snapshotを
取得しないため、通常実行の計測負荷は増やさない。

`RobotSim.EnduranceReport`は新eventを個別に集計し、kernel stop / start failureがあれば`successful: false`とする。過去のlogには
新eventがないため、event数が0でも従来のrestart集計を壊さない。

## Host検証

`examples/hello_atomvm_modbus_robot/`で次を実行した。

```sh
mise exec -- mix format --check-formatted
mise exec -- mix test
```

結果は122 tests、0 failuresだった。途中のfocused runではconnection trace、endurance report、startup recovery matrixの
30 testsも0 failuresだった。

## AtomVM compatibilityとPackBEAM

Controller、Drive、Sensorsの各roleについて、次の条件で`mix atomvm.check`と`mix atomvm.packbeam`を実行した。

```sh
ROBOT_MODE=multinode \
ROBOT_ROLE=<controller|drive|sensors> \
ROBOT_MULTINODE_CONNECTION_TRACE=true \
ROBOT_MULTINODE_METRICS_INTERVAL_MS=10000 \
ATOMVM_UART_SPEED=115200 \
MIX_ENV=prod \
mise exec -- mix atomvm.check
```

3 roleとも成功した。PackBEAM時の`No avm_deps directory found`は、standard libraryをAtomVMのlib partitionへ導入済みの
現在の構成では既知の案内であり、build failureではない。

## 判断

- `kernel_start_succeeded`は`net_kernel.start/2`の戻り値だけを表す。
- distribution recovery成功には、その後の`readiness_acknowledged`、`remote_reconnected`、`recovery_verified`が必要である。
- restart budget、90秒health timeout、8秒initial observation timeoutは変更していない。
- 2026-10-26に3台へのflashとcurrent policyの短時間 / health timeout超過branch切断を実施した。結果は
  [current policy baseline](2026-10-26-stage-7-current-policy-baseline.md)へ分けて記録する。

次はcurrent policyの実測を基準に、transport復帰後までrestartを保留する条件を設計する。
