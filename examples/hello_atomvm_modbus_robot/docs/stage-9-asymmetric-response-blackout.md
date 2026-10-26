# Stage 9 非対称response blackout試験

状態: 実機試験準備中

## 目的

ControllerからSensorsへのFC-100 requestは届く一方、SensorsのresponseだけがControllerへ届かない非対称障害を再現する。
Current / deferred recovery policyの動作を比較し、Stage 8のtransport activity signalで扱える範囲を明確にする。

## 観測境界

`ROBOT_MULTINODE_EXCHANGE_TRACE=true`を指定したremoteは、次のeventを出力する。

| Event | 確認できること | 確認できないこと |
| --- | --- | --- |
| `request_accepted` | Server adapterがFC-100 requestをdecodeし、Channelへ反映した | responseの送信・到達 |
| `response_returned` | AdapterがresponseをAVModbus Serverへ返した | UART送信完了、Controller受信 |
| `response_dropped` | Fault injectionがresponseを`server_device_failure`へ置き換えた | Controller側の最終状態 |

同じadapter内では`exchange_id`が単調増加し、requestとresponse outcomeを対応付ける。Adapter restart後は1から再開する。
Controllerでのresponse受信は`MODBUS_TRACE_TRANSACTIONS=true`のtransaction結果とmetricsで別に確認する。
Robot exampleはconsole出力によるtimingへの影響を抑えるため、破棄対象requestとfault終了後の最初のresponseだけを記録する。

既存のtransport activity observerはrequestを受理した時点でexchange activityを更新する。そのためresponse blackout中も
`last_exchange_ms`が更新され、長時間gap後の`transport_resumed` / `transport_ready`は発生しないと予測する。

## 試験matrix

Sensorsだけでresponse faultとexchange traceを有効にする。Driveは同じbus上で通常動作を継続させる。

| Policy | `ROBOT_MULTINODE_DEFER_RESTART_UNTIL_TRANSPORT_READY` | Runs |
| --- | --- | ---: |
| Current | `false` | 2 |
| Deferred | `true` | 2 |

共通profile:

```text
ROBOT_MODE=multinode
ATOMVM_UART_SPEED=115200
ROBOT_MULTINODE_CONNECTION_TRACE=true
ROBOT_MULTINODE_REMOTE_HEALTH_ENABLED=true
ROBOT_MULTINODE_REMOTE_HEALTH_TRACE=true
ROBOT_MULTINODE_REMOTE_ACK_TIMEOUT_MS=90000
ROBOT_MULTINODE_REMOTE_MAX_RESTARTS=1
ROBOT_MULTINODE_METRICS_INTERVAL_MS=10000
```

Sensorsだけに追加する設定:

```text
MODBUS_FAULT_DROP_RESPONSES=180
MODBUS_FAULT_MIN_PAYLOAD_BYTES=0
MODBUS_FAULT_AFTER_MS=60000
MODBUS_FAULT_REARM_ON_RESTART=false
ROBOT_MULTINODE_EXCHANGE_TRACE=true
```

Controllerだけで`MODBUS_TRACE_TRANSACTIONS=true`を指定する。Application trafficは無効とし、recovery-onlyとして評価する。

## 手順

1. 3台をresetし、両remoteのreadiness ACK、mission完了、queue drainを確認する。
2. Sensorsの`response_dropped`開始と、ControllerのUnit 2 transaction failure開始を記録する。
3. Fault budget消費中もSensorsの`request_accepted`が継続するか確認する。
4. 最後の`response_dropped`後、最初の`response_returned`とController transaction successを確認する。
5. Remote health timeout、restart、reconnect、recovery probeを最大180秒観測する。
6. Drive connection、queue、free heap、restart budgetを記録する。
7. 次のrun前に3台をresetし、connection IDとrestart budgetを持ち越さない。

## 判定項目

- `request_accepted`と`response_dropped`の対応
- Fault終了後の`response_returned`とController transaction success
- `transport_resumed` / `transport_ready`の有無
- restart started / succeeded / budget exhausted
- Sensors reconnectとrecovery probe
- Drive connectionの維持
- Controller global queue rejectionと3 roleのminimum free heap

Stage 9では新しいrecovery signalをまだ追加しない。まず既存signalの限界を同じevent schemaで再現し、双方向成立の判定に
追加情報が必要かを決める。
