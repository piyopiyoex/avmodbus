# Concurrent producer traffic baseline — 2026-10-20

## 目的

Controller から順番に echo request を送る従来 soak だけでなく、Drive と Sensors が独立 process から logical message を生成した場合に、
1本の Modbus RTU bus と2本の Erlang distribution connectionを維持して配送できるか確認する。短時間の baseline と moderate profile で
delivery、ordering、role 間の重複稼働時間、公平性の初期値を得る。

wire 上では Controller だけが Modbus Client として transaction を開始する。したがって「concurrent」は独立した producer と logical
traffic を意味し、half-duplex RS485 上で複数 request が同時送信されることを意味しない。

## 実装と Host 検証

- Drive / Sensors に role ごとの独立 producer process を起動する
- Controller に独立 collector process を置き、readiness loop を同期的に停止しない
- run ID、role、sequence、payload を検証する
- sample 数と payload size を compile-time 設定し、64 sample / role、128 bytes に制限する
- expected / received、missing、duplicate、out-of-order、invalid、duration、throughput、interarrival を集計する
- Controller で観測した start / finish window から active overlap と completion skew を計算する

実装後の host test は次のとおり成功した。

```text
examples/hello_atomvm_modbus_disterl: 60 tests, 0 failures
examples/hello_atomvm_modbus_robot:   52 tests, 0 failures
repository root:                     228 tests, 6 properties, 0 failures
```

## Managed client handle の互換性修正

最初の Controller 起動は `Drive adapter start failed {:error, :invalid_client}` で停止した。shared multidrop client を
`DisterlProbe.ModbusUART` へ渡す経路が raw PID だけを受理していた一方、現在の `AVModbus.Client.start_link/1` は
`{AVModbus.Client, server}` managed handle を返すことが原因だった。

`ModbusUART` が serial managed handle と既存の raw PID compatibility の両方を受理するよう修正し、両形式の回帰 test を追加した。
AVModbus core と FC-100 wire protocol は変更していない。修正後、Controller は1個の managed client を2個の adapter で共有し、
Drive / Sensors の両 FC-100 peer と接続した。

## Hardware と build

| Role | Unit ID | Port | USB serial | PackBEAM size |
| --- | ---: | --- | --- | ---: |
| Drive | 1 | `/dev/ttyACM0` | `38:44:BE:A5:04:DC` | 243,828 bytes |
| Sensors | 2 | `/dev/ttyACM1` | `10:BD:A3:CF:09:04` | 243,796 bytes |
| Controller | Client | `/dev/ttyACM2` | `38:44:BE:A5:05:14` | 248,360 bytes |

- 3 × Seeed Studio XIAO ESP32-C5
- 3 × HW-519、shared two-wire RS485、common ground
- AtomVM v0.7.0-beta.0 と既存 multi-connection local patch
- 115,200 baud
- FC-100 chunk payload 96 bytes
- Modbus poll interval 20 ms

Drive と Sensors を通常 multinode firmware で起動し、Controller の sensor-driven mission 完了後に traffic probe を自動開始した。
profile 間では remote session と Controller session を再起動し、古い distribution handshake の残留を避けた。
測定後、Controller は `ROBOT_MULTINODE_TRAFFIC_SAMPLES=0` の通常 firmware（248,036 bytes）へ戻し、flash hash verification を完了した。
3 role を Drive、Sensors、Controller の順に再起動し、通常の adaptive mission が全 request を attempt 1 で完了して
final state `(x=200, y=0, heading=90°)` になることも再確認した。

## Baseline

設定は Drive 2,000 ms、Sensors 1,000 ms、各5 messages、16-byte payload である。

```text
modbus_robot_traffic: start run=4103977675 samples_per_role=5 payload_bytes=16
modbus_robot_traffic: complete run=4103977675 ... outcome=:complete ...
modbus_robot_multinode: concurrent traffic report run=4103977675 outcome=complete
```

| Metric | Drive | Sensors |
| --- | ---: | ---: |
| expected / received | 5 / 5 | 5 / 5 |
| missing / duplicates | 0 / 0 | 0 / 0 |
| out-of-order / invalid | 0 / 0 | 0 / 0 |
| duration | 8,593 ms | 4,634 ms |
| sample span | 7,058 ms | 3,086 ms |
| throughput | 581 milli-msg/s | 1,078 milli-msg/s |
| max interarrival | 2,136 ms | 795 ms |

run elapsed は10,588 ms、start skew は186 ms、active overlap は4,448 ms、completion skew は4,145 ms、
delivery ratio gap は0‰、max interarrival gap は1,341 msだった。両 producer の受信 window が実際に重なり、baseline の成功条件を満たした。

## Moderate profile

設定は Drive 1,000 ms、Sensors 500 ms、各10 messages、32-byte payload である。

```text
modbus_robot_traffic: start run=479100172 samples_per_role=10 payload_bytes=32
modbus_robot_traffic: complete run=479100172 ... outcome=:complete ...
modbus_robot_multinode: concurrent traffic report run=479100172 outcome=complete
```

| Metric | Drive | Sensors |
| --- | ---: | ---: |
| expected / received | 10 / 10 | 10 / 10 |
| missing / duplicates | 0 / 0 | 0 / 0 |
| out-of-order / invalid | 0 / 0 | 0 / 0 |
| duration | 9,592 ms | 8,840 ms |
| sample span | 8,038 ms | 7,245 ms |
| throughput | 1,042 milli-msg/s | 1,131 milli-msg/s |
| max interarrival | 1,195 ms | 824 ms |

run elapsed は11,593 ms、start skew は185 ms、active overlap は8,655 ms、completion skew は937 ms、
delivery ratio gap は0‰、max interarrival gap は371 msだった。送信間隔と payload を増やしたこの profile でも starvation、loss、
duplicate、ordering error は観測しなかった。

## 観察した recovery log

試験 profile の切り替え中に remote session を再起動すると、Controller の古い `serial_dist_controller` reader は
`{serial_read_error, closed}` で終了し、その後に新 session へ再接続した。これは既存の reboot recovery で記録済みの挙動と一致する。
また、古い Controller と remote の distribution handshake を途中のまま再利用すると `unexpected recv_challenge_reply` が繰り返されたため、
測定 run は3 role の session を揃えてから開始した。profile の測定値にはこの準備中の recovery traffic を含めていない。

## 測定上の制約

- Controller と remote の monotonic clock は同期していないため、one-way latency は算出していない
- throughput と interarrival は Controller の受信時刻だけから計算した
- 各 profile は1 run の短時間測定であり、統計的な性能評価ではない
- application mailbox、FC-100 queue、managed client queue の個別 depth はまだ同時記録していない
- heap / memory の長時間推移、physical cable interruption、overload profile は未検証
- message delivery は session-scoped で、reboot をまたぐ durable delivery ではない

## 結論

Drive と Sensors の独立 producer は、共有 Modbus RTU bus 上の2本の genuine Erlang distribution connection を使い、baseline と
moderate の両 profile で欠損なく同時稼働した。短時間の範囲では一方の role の starvation は観測しなかった。

次は trace を有効にして queue depth と physical transaction を対応付けること、長時間 soak と memory 推移、remote reboot または
physical disconnection 中の collector semantics を優先する。exploratory overload と4台目への拡張は、その測定後に判断する。
