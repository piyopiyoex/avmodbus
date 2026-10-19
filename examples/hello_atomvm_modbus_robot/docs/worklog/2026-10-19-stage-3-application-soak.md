# Stage 3 application traffic soak — 2026-10-19

## 目的

3-node distribution の初回 probe と reboot recovery に続き、Drive と Sensors の両 stream に継続した application payload を流し、
shared Modbus Client 上で片方が停滞しないことと role 別の end-to-end RTT を確認する。

## 実装

Controller に opt-in の soak mode を追加した。1 cycle で Drive と Sensors に同じ payload を 1 回ずつ送り、remote は受信内容を
そのまま返す。Controller は `DisterlProbe.Payload` の既知 pattern で request を作り、reply が完全一致する場合だけ成功とする。

固定順による latency bias を減らすため、odd cycle は Drive、even cycle は Sensors を先に送る。測定は sequential であり、2 role
へ同時送信する throughput test ではない。role ごとに success / failure と min / average / max RTT を集計する。

設定値は次のとおり。

| 項目 | 値 |
| --- | ---: |
| UART | 115,200 baud |
| FC-100 chunk payload | 96 bytes |
| application payload | 128 bytes |
| cycle interval | 250 ms |
| per-probe timeout | 60,000 ms |
| Drive | Unit 1, `/dev/ttyACM0` |
| Sensors | Unit 2, `/dev/ttyACM1` |
| Controller | `/dev/ttyACM2` |

128-byte application payload を含む distribution message は Controller 側で 317 bytes または 319 bytes になり、96-byte chunk へ
分割された。更新後の PackBEAM は Controller 227,628 bytes、Drive 222,848 bytes、Sensors 222,624 bytes だった。3 台とも flash
後の hash verification に成功した。

## 10-cycle baseline

最初に 10 cycle / 20 round trip を実行した。

| Role | Success | Failure | Min RTT | Average RTT | Max RTT |
| --- | ---: | ---: | ---: | ---: | ---: |
| Drive | 10 | 0 | 3,130 ms | 3,189 ms | 3,229 ms |
| Sensors | 10 | 0 | 3,133 ms | 3,180 ms | 3,228 ms |

- elapsed: 66,298 ms
- success count delta: 0
- failure count delta: 0
- average RTT delta: 9 ms

## 30-cycle baseline

Controller だけを 30 cycle configuration で再 build / flash し、動作中の Drive と Sensors へ再接続して 60 round trip を実行した。

| Role | Success | Failure | Min RTT | Average RTT | Max RTT |
| --- | ---: | ---: | ---: | ---: | ---: |
| Drive | 30 | 0 | 3,130 ms | 3,184 ms | 3,234 ms |
| Sensors | 30 | 0 | 3,133 ms | 3,180 ms | 3,231 ms |

- elapsed: 198,745 ms
- success count delta: 0
- failure count delta: 0
- average RTT delta: 4 ms
- payload mismatch: 0
- distribution timeout / reconnect: 0

## 結論と制約

約 3 分間の継続 application traffic では両 role が 30 / 30 reply を返し、平均 RTT の差は 4 ms だった。今回の交互順・sequential
workload では、shared Client の一方が停止または顕著に遅延する現象は観測されなかった。

これは polling scheduler の一般的な fairness 証明ではない。長時間運転、concurrent producer、異なる payload size、timeout を伴う
traffic は未検証である。soak 中の remote reboot は後続の
[recovery 試験](2026-10-19-stage-3-soak-reboot.md) で確認した。
