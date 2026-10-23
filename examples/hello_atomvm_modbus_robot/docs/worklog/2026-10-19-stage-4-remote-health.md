# Stage 4 リモート健全性と独立復旧 — 2026-10-19

## 目的

Controller が Drive / Sensors の停止を role ごとに検出し、稼働中 peer を維持したまま復帰 node を再登録できるか確認する。また、
AtomVM distributed process monitor が現在の alternative carrier で利用できるか調査する。

## Distributed process monitor の試行

Controller が readiness announcer の remote PID に `Process.monitor/1` を設定する実装を3台へ flash した。Sensors 接続直後、
`erlang:monitor/2` が `badarg` を返し Controller application が終了した。

```text
modbus_robot_multinode: connected role=sensors node=:sensors@modbus.local
CRASH
pid: <0.1.0>
...
[{13,1835,erlang,monitor,2}]
...
x[1]: badarg
```

[AtomVM distributed Erlang documentation](https://doc.atomvm.org/release-0.7/distributed-erlang.html) は process monitoring を feature として
記載している。したがって monitor 全般が非対応とは結論せず、AtomVM v0.7.0-beta.0 の2つの AtomVM node、external PID、
`serial_dist` alternative carrier を組み合わせた場合の blocker として記録する。

## Readiness leaseによるfallback

native monitor を削除し、既存 readiness heartbeat を role ごとの lease として扱うようにした。

- heartbeat 受信時に monotonic timestamp を更新する
- health check ごとに `now - last_seen > lease` の role を unavailable にする
- boot session が同じ heartbeat は duplicate connection ではなく lease refresh として扱う
- stale role だけを state から外し、peer entry は維持する
- readiness が再開したら従来の session-aware reconnect と両 role probe を実行する

host test は metadata を含む duplicate 判定、片方だけの expiry、deadline 境界を含む。

```text
mix format --check-formatted
mix test
mix atomvm.check

45 tests, 0 failures
```

## Leaseの調整

最初の test profile は heartbeat 2秒、health check 1秒、lease 5秒とした。adaptive mission 終了後、heartbeat が Modbus / distribution
queue を通過する前に両 role の lease が expired となった。その直後に heartbeat を受けて両方とも recovery したが、5秒 lease は
false positive を生むため不採用とした。

次の profile では30秒間の idle monitoring で false positive は発生しなかった。

| 項目 | Test profile | Default |
| --- | ---: | ---: |
| readiness heartbeat | 5,000 ms | 30,000 ms |
| health check | 2,000 ms | 5,000 ms |
| lease | 20,000 ms | 75,000 ms |

## 実機条件

| Role | Unit ID | Port | PackBEAM size |
| --- | ---: | --- | ---: |
| Drive | 1 | `/dev/ttyACM0` | 232,812 bytes |
| Sensors | 2 | `/dev/ttyACM1` | 232,820 bytes |
| Controller | Client | `/dev/ttyACM2` | 236,724 bytes |

- 3 × Seeed Studio XIAO ESP32-C5
- shared two-wire RS485 bus、115,200 baud
- FC-100 chunk payload 96 bytes
- AtomVM v0.7.0-beta.0 と Stage 3 の local multi-connection tick patch

各 Server は `esptool --after no-reset flash-id` で flash を変更せず flasher stub に留め、20秒以上 application を停止した。その後
`esptool run` で application を再起動した。

## Drive outage と recovery

Drive 停止中は Modbus poll timeout が発生したが、Sensors heartbeat は継続した。Controller は Drive だけを expired とした。

```text
modbus_robot_multinode: readiness lease expired role=drive
```

Drive を再起動すると FC-100 session change と distribution reader close を経て再接続し、両 role の probe が成功した。

```text
modbus_robot_multinode: reconnected role=drive node=:drive@modbus.local
modbus_robot_multinode: probe reply role=drive node=:drive@modbus.local
modbus_robot_multinode: probe reply role=sensors node=:sensors@modbus.local
modbus_robot_multinode: recovery complete restarted=drive peer=sensors
```

## Sensors outage と recovery

同じ手順で Sensors だけを停止すると、Drive lease を維持したまま Sensors だけを expired とした。

```text
modbus_robot_multinode: readiness lease expired role=sensors
modbus_robot_multinode: reconnected role=sensors node=:sensors@modbus.local
modbus_robot_multinode: probe reply role=sensors node=:sensors@modbus.local
modbus_robot_multinode: probe reply role=drive node=:drive@modbus.local
modbus_robot_multinode: recovery complete restarted=sensors peer=drive
```

両 recovery で古い `serial_dist_controller` reader の `{serial_read_error, closed}` crash report が出たが、Controller の `net_kernel` と
停止していない peer connection は継続した。

## 結論と制約

- application readiness lease により Drive / Sensors の停止を独立に検出し、復帰後の messaging を再確認できた
- 20秒 test lease では idle 時の false positive は発生しなかった
- native distributed process monitor は現在の構成では利用できなかった
- default 75秒 lease の長時間 false-positive rate は未測定である
- mission 実行中は Controller が同期的に reply を待つため、lease expiry を処理しない
- mission 中の interruption、partial progress reconciliation、remote application process だけの crash は未検証である
