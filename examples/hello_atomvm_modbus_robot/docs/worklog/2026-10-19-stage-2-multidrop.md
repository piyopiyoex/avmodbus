# Stage 2 three-device standard Modbus multidrop — 2026-10-19

## 目的

3-node distributed Erlang へ進む前に、1 台の Modbus Client が shared two-wire RS485 bus 上の 2 台の Server を
Unit ID で選択し、transaction を重ねず安定して poll できることを確認する。この試験では Erlang distribution と FC-100 を
使わない。

## Hardware

| Role | Port | USB serial | Modbus role |
| --- | --- | --- | --- |
| Controller | `/dev/ttyACM2` | `38:44:BE:A5:05:14` | Client / bus owner |
| Drive | `/dev/ttyACM0` | `38:44:BE:A5:04:DC` | Server Unit 1 |
| Sensors | `/dev/ttyACM1` | `10:BD:A3:CF:09:04` | Server Unit 2 |

- 3 × Seeed Studio XIAO ESP32-C5
- 3 × HW-519
- shared two-wire RS485 bus、common signal ground
- UART1: TX GPIO23、RX GPIO24、9,600 baud、8N1
- RTU transmit gap 20 ms、response timeout 500 ms、read retry 1回
- AtomVM runtime: `v0.7.0-beta.0+git.8d3e051`

新しい Sensors board には local 保存済みの公式 `AtomVM-esp32c5-elixir-v0.7.0-beta.0.img` を install した。image SHA-256 は
`2fcf4c8aa3c3df5c7a0c6a4be18fc437342baf6765e355ea75275ba7b89e38ad` であり、flash hash verification は成功した。
この board の boot library には Stage 1 で使用した local `net_kernel` patch がまだ入っていない。Stage 2 では distribution を
開始しないため結果に影響しないが、Stage 3 の前に 3 台の boot library を揃える必要がある。

termination / bias resistance は今回個別に測定していない。記録値は現在の配線と HW-519 module の構成に限る。

## Probe protocol

Controller は各 cycle で必ず次の順序で Function Code 3 を送る。

1. Unit 1 の holding register 0–1 を読み、`[1, 1]` を検証する
2. Unit 2 の holding register 0–1 を読み、`[2, 2]` を検証する

先頭値は role code、2 番目は Unit ID である。AVModbus managed Client が UART を単独所有し、active transaction を 1 件に
制限する。Server は AVModbus RTU Server の unit filtering を利用する。

## Baseline と soak

default 3 cycle / 6 request はすべて成功した。続いて `ROBOT_MULTIDROP_CYCLES=60` で短時間 soak を実行した。

```text
modbus_robot_multidrop: cycle=1 role=drive unit=1 elapsed_ms=184 reply={:ok, [1, 1]}
modbus_robot_multidrop: cycle=1 role=sensors unit=2 elapsed_ms=175 reply={:ok, [2, 2]}
...
modbus_robot_multidrop: cycle=60 role=drive unit=1 elapsed_ms=175 reply={:ok, [1, 1]}
modbus_robot_multidrop: cycle=60 role=sensors unit=2 elapsed_ms=182 reply={:ok, [2, 2]}
modbus_robot_multidrop: complete result={:ok, %{successes: 120, failures: 0, drive_successes: 60, sensors_successes: 60, ...}}
```

| Metric | Drive Unit 1 | Sensors Unit 2 |
| --- | ---: | ---: |
| Success | 60 / 60 | 60 / 60 |
| Failure | 0 | 0 |
| Observed request latency | 175–184 ms | 175–182 ms |

Controller start から summary まで約 81.8 秒だった。全 cycle で Drive→Sensors の順序を維持し、CRC error、timeout、
unexpected register、unit collision は記録されなかった。これは長時間 soak や performance benchmark ではない。

## Independent Server reboot

12 cycle / 24 request build を使い、Controller を動かしたまま各 Server を別々に RTS reset した。

Drive reboot run では cycle 5 の Drive request が 799 ms に伸びた。最初の attempt 中に Drive が再起動し、read retry 内で
応答した。同じ cycle の Sensors は 175 ms で成功し、最終結果は 24 / 24 成功だった。

```text
cycle=5 role=drive unit=1 elapsed_ms=799 reply={:ok, [1, 1]}
cycle=5 role=sensors unit=2 elapsed_ms=175 reply={:ok, [2, 2]}
```

Sensors reboot run では cycle 5 の Sensors request が 197 ms で成功し、同じ cycle の Drive は 174 ms だった。Sensors は
request が完了する前に server-ready へ戻り、最終結果は同じく 24 / 24 成功だった。

これらの run では 1 台の Server reboot が他方の response を壊さず、Controller の UART process も再起動を必要としなかった。
より長い停止で retry を使い切る場合、Controller は failure を role 別に数えた後も次の Unit と cycle を poll し続けるが、
その hardware fault injection は今回実施していない。

## 結論

Stage 2 の standard Modbus RTU multidrop は 3 台の実機で成立した。single Client ownership と固定 Drive→Sensors schedule に
より、同じ RS485 bus 上の 2 台を独立して addressing できた。次の Stage 3 では、この physical topology 上に Unit ごとの
FC-100 session と複数の distribution stream を構成できるかを調査する。
