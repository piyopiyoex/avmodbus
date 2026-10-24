# Stage 3 通信中のリモート再起動 — 2026-10-19

## 目的

Controller が application payload の reply を待っている間に Drive または Sensors が再起動しても、新しい distribution connection を
認識し、もう一方の stream を失わずに soak traffic を完了できるか確認する。

## 実装

soak probe の receive loop でも readiness message を処理し、role ごとの PID と boot session ID を更新するようにした。

- 待機対象と同じ role の新 boot session: ACK 後、同じ soak ID と payload を新しい reference で 1 回再送する
- 別 role の新 boot session: ACK と state 更新後、元の reply を待ち続ける
- 同じ PID / boot session: duplicate heartbeat として ACK し、元の reply を待ち続ける
- node 名が role identity と不一致: reject し、元の reply を待ち続ける

再送前後を合わせた時間を RTT として記録する。既定の `ROBOT_MULTINODE_SOAK_RETRIES` は `1` である。この retry は内容検証だけを
行う echo probe が idempotent であることを前提とする。movement command の重複実行防止や exactly-once delivery には利用しない。

readiness transition は pure function として host test し、対象 role の restart、peer restart、duplicate heartbeat をそれぞれ固定した。

## 実機条件

| 項目 | 値 |
| --- | ---: |
| soak cycles | 20 |
| total round trips | 40 |
| application payload | 128 bytes |
| FC-100 chunk payload | 96 bytes |
| UART | 115,200 baud |
| retry limit | 1 |
| Drive | Unit 1, `/dev/ttyACM0` |
| Sensors | Unit 2, `/dev/ttyACM1` |
| Controller | `/dev/ttyACM2` |

PackBEAM は Controller 228,936 bytes、Drive 223,040 bytes、Sensors 222,816 bytes だった。3 台とも flash 後の hash verification に
成功した。

## Driveの再起動

cycle 3 の Drive request 送信直後に Drive を reset した。すでに転送済みの cycle 3 reply は成功し、FC-100 session change は
cycle 4 の Drive probe 中に検出された。古い `serial_dist_controller` reader は `{serial_read_error, closed}` で終了し、新しい
distribution connection と boot session を認識した。

```text
modbus_robot_multinode: reconnected during soak role=drive node=:drive@modbus.local
modbus_robot_multinode: soak retry role=drive id={4, :drive} remaining=0
modbus_robot_multinode: soak cycle=4 role=drive rtt_ms=11847 payload_bytes=128
```

再送後は通常の約 3.1–3.3 秒 RTT に戻り、Sensors traffic も timeout しなかった。

## Sensorsの再起動

cycle 14 の Sensors request 送信直後に Sensors を reset した。session change は cycle 16 の Sensors probe 中に検出され、新しい
boot session への 1 回再送で成功した。

```text
modbus_robot_multinode: reconnected during soak role=sensors node=:sensors@modbus.local
modbus_robot_multinode: soak retry role=sensors id={16, :sensors} remaining=0
modbus_robot_multinode: soak cycle=16 role=sensors rtt_ms=9887 payload_bytes=128
```

Drive traffic は継続し、recovery 後は Sensors も通常 RTT に戻った。

## 結果

| Role | Success | Failure | Min RTT | Average RTT | Max RTT |
| --- | ---: | ---: | ---: | ---: | ---: |
| Drive | 20 | 0 | 3,128 ms | 3,617 ms | 11,847 ms |
| Sensors | 20 | 0 | 3,131 ms | 3,516 ms | 9,887 ms |

- elapsed: 147,874 ms
- retry: Drive 1、Sensors 1
- success count delta: 0
- failure count delta: 0
- average RTT delta: 101 ms
- payload mismatch: 0
- application timeout: 0

完了後も 35 秒監視し、両 readiness heartbeat と connection の継続を確認した。reader close の crash report は各 reboot で出力されたが、
Controller の `net_kernel` と reboot していない peer connection は継続した。

## 結論と制約

今回の idempotent echo workload では、Drive / Sensors の各 1 回の reboot を active traffic 中に吸収し、40 / 40 round trip を
完了できた。reboot の影響は該当 probe の RTT 増加として現れ、peer の failure には波及しなかった。

長時間 soak、2 台の同時 reboot、retry exhaustion、non-idempotent command、複数 concurrent producer は未検証である。
