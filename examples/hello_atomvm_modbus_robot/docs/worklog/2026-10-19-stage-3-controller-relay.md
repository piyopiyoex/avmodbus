# Stage 3 Controller経由のセンサー中継 — 2026-10-19

## 目的

Modbus RTU Server である Sensors と Drive が physical bus を直接駆動せず、Controller が持つ 2 本の genuine distributed Erlang
connection を経由して application data を中継できるか確認する。

## 実装

- `RobotSim.Sensors` は deterministic な distance と battery sample を生成する
- `RobotSim.Relay` は Sensors へ sample を要求し、検証後に Drive へ転送する
- `RobotSim.Drive` は最後に受理した sample と送信元 node を保持し、明示的な ACK または reject を返す
- Sensors process は `:modbus_robot_sensors`、Drive process は `:modbus_robot_drive` として各 remote node に登録する
- FC-100 transport probe と AVModbus core は変更しない

最初の sample は次の値である。sequence ごとに deterministic に変化し、reboot 後は sequence 1 へ戻る。

```elixir
%{sequence: 1, distance_mm: 500, battery_percent: 100}
```

## Host 検証

local PID を宛先として同じ Sensors request、Controller relay、Drive ACK を実行した。sample の生成規則、値域、不正 sample の拒否、
Drive への保存、sequence increment を test した。

```text
mix format --check-formatted
mix test
mix atomvm.check

36 tests, 0 failures
```

`ROBOT_MODE=multinode` と各 role の組み合わせでも AtomVM compatibility check と PackBEAM build に成功した。

| Role | PackBEAM size |
| --- | ---: |
| Drive | 227,928 bytes |
| Sensors | 227,940 bytes |
| Controller | 231,540 bytes |

## 実機条件

| Role | Unit ID | USB serial | Port |
| --- | ---: | --- | --- |
| Drive | 1 | `38:44:BE:A5:04:DC` | `/dev/ttyACM0` |
| Sensors | 2 | `10:BD:A3:CF:09:04` | `/dev/ttyACM1` |
| Controller | Client | `38:44:BE:A5:05:14` | `/dev/ttyACM2` |

- 3 × Seeed Studio XIAO ESP32-C5
- shared two-wire RS485 bus
- UART 115,200 baud
- FC-100 chunk payload 96 bytes
- AtomVM v0.7.0-beta.0 と Stage 3 で記録した local multi-connection tick patch

3 role を個別に clean、pack、flash し、Drive と Sensors の起動後に Controller console を監視した。

## 結果

Controller は両 remote への基本 probe を完了した後、Sensors から sample を受け取り、Drive の ACK を確認した。

```text
modbus_robot_multinode: probe reply role=drive node=:drive@modbus.local
modbus_robot_multinode: probe reply role=sensors node=:sensors@modbus.local
modbus_robot_multinode: relay complete sensors=:sensors@modbus.local drive=:drive@modbus.local sample=%{sequence: 1, distance_mm: 500, battery_percent: 100}
modbus_robot_multinode: complete Drive and Sensors remote messaging
```

これにより `Sensors -> Controller -> Drive` の 3-node application message path を実機で確認した。Drive の ACK は sample 全体を返すため、
Controller は転送した値と受理された値が一致することも確認している。

## 制約

- relay 全体の RTT は今回測定していない
- sample と Drive の last sample は RAM 上だけにあり、remote reboot 後は失われる
- timeout 後の自動再送と sample ID による重複排除はまだ実装していない
- sample に基づく mission decision、obstacle 判定、fault recovery は Stage 4 の対象である
- Drive と Sensors の直接 communication は実装していない
