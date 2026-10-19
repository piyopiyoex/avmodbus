# Stage 4 sensor-driven adaptive mission — 2026-10-19

## 目的

Sensors の値を単に relay するだけでなく、Controller が navigation command を選び、Drive の virtual rover state を変えられるか
3 台の ESP32-C5 で確認する。

## 実装

`RobotSim.Navigator` は sample から次の pure decision を返す。

| 優先順位 | 条件 | reason | command |
| ---: | --- | --- | --- |
| 1 | battery `<= 20%` | `:low_battery` | `:status` |
| 2 | distance `<= 400 mm` | `:obstacle` | `{:turn, :right, 90}` |
| 3 | それ以外 | `:clear_path` | `{:forward, 100}` |

`RobotSim.SensorMission` は各 step を次の順で直列実行する。

```text
Sensors sample -> Controller validation -> Drive relay ACK
              -> Controller decision -> Drive command/reply
```

最後に `:status` command で Drive の final state を読み直す。command timeout の再送では同じ request ID を使う。Controller の
新しい起動では `DisterlProbe.Session.new_id/0` から別の request-ID range を始め、既存 Drive cache と異なる command が衝突する
可能性を下げる。

## Host 検証

- clear path、obstacle threshold、low battery の優先順位
- malformed sample の拒否
- mission step 数と request ID の validation
- local Sensors / Drive process による 3-step end-to-end mission

fresh Sensors の sample と期待 command は次のとおりである。

| Step | Distance | Battery | Decision |
| ---: | ---: | ---: | --- |
| 1 | 500 mm | 100% | 100 mm 前進 |
| 2 | 450 mm | 99% | 100 mm 前進 |
| 3 | 400 mm | 98% | 右へ 90° 旋回 |

```text
mix format --check-formatted
mix test
mix atomvm.check

42 tests, 0 failures
```

## 実機条件

| Role | Unit ID | Port | PackBEAM size |
| --- | ---: | --- | ---: |
| Drive | 1 | `/dev/ttyACM0` | 232,356 bytes |
| Sensors | 2 | `/dev/ttyACM1` | 232,368 bytes |
| Controller | Client | `/dev/ttyACM2` | 235,816 bytes |

- 3 × Seeed Studio XIAO ESP32-C5
- shared two-wire RS485 bus
- UART 115,200 baud
- FC-100 chunk payload 96 bytes
- AtomVM v0.7.0-beta.0 と Stage 3 の local multi-connection tick patch
- `ROBOT_SENSOR_MISSION_STEPS=3`

3 role すべてで AtomVM compatibility check、PackBEAM、flash、hash verification に成功した。

## 結果

Controller は sample ごとに異なる command を選び、fresh Drive を期待 state まで動かした。

```text
modbus_robot_multinode: sensor mission step=1 sample=%{sequence: 1, distance_mm: 500, battery_percent: 100} reason=clear_path command={:forward, 100} state=%{y_mm: 0, x_mm: 100, heading_deg: 0, __struct__: RobotSim.Rover}
modbus_robot_multinode: sensor mission step=2 sample=%{sequence: 2, distance_mm: 450, battery_percent: 99} reason=clear_path command={:forward, 100} state=%{y_mm: 0, x_mm: 200, heading_deg: 0, __struct__: RobotSim.Rover}
modbus_robot_multinode: sensor mission step=3 sample=%{sequence: 3, distance_mm: 400, battery_percent: 98} reason=obstacle command={:turn, :right, 90} state=%{y_mm: 0, x_mm: 200, heading_deg: 90, __struct__: RobotSim.Rover}
modbus_robot_multinode: sensor mission complete state=%{y_mm: 0, x_mm: 200, heading_deg: 90, __struct__: RobotSim.Rover}
```

最終 artifact の確認では全 movement command と final status が attempt 1 で成功し、transport poll timeout、application timeout、
request-ID conflict、mission failure は発生しなかった。実装途中の最初の run では FC-100 poll timeout が 1 回発生したが、transport
retry で回復し、同じ final state に到達した。

## 制約

- low-battery decision は host test のみで、3-board mission では未到達である
- mission 全体および step ごとの RTT は未計測である
- command retry は Drive の bounded in-memory cache に依存する
- remote reboot 後の rover state、sensor sequence、completed command cache は復元されない
- mission 中の node reboot、process monitoring、reconciliation は未検証である
