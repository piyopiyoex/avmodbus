# 既知の制約

このページは virtual robot application と3-node構成に固有の制約をまとめます。FC-100 byte-stream carrier 自体の制約は
[Modbus distributed Erlang example の既知の制約](../../hello_atomvm_modbus_disterl/docs/limitations.md)、個別の実測結果は
[作業記録](worklog/README.md) を参照してください。

## 構成と通信経路

- 固定された `controller`、`drive`、`sensors` の3 role、Unit ID 1 / 2 の構成だけを対象とします。dynamic discovery、routing、
  4 node 以上への拡張は実装していません。
- Modbus Server である Drive と Sensors は bus を自発的に駆動できません。両者の application message は Controller が relay し、
  すべての physical transaction は1個の Modbus Client が直列化します。
- Controller は Drive / Sensors ごとに独立した distribution stream を持ちますが、physical UART と AVModbus Client を共有します。
  同時 producer の一般的な fairness と長時間負荷は未検証です。
- 3-node distribution は AtomVM v0.7.0-beta.0 に対する local multi-connection tick patch を必要とします。公式 image のまま動作する
  production 構成ではありません。

## Buffer と backpressure

- FC-100 carrier の outgoing queue は stream ごとに default 8,192 payload bytes / 256 chunks です。Controller の2 stream は独立した
  上限を持ちます。
- 上限は carrier が保持する payload の合計であり、binary、Erlang term、process mailbox、distribution controller を含む VM heap
  全体の上限ではありません。application process の mailbox に明示的な件数上限はありません。
- queue 上限を超えた write は `{:error, :queue_full}` となり、carrier は fail fast して session を切り替えます。queue 済みまたは
  in-flight の stream data は破棄されるため、回復は application の timeout / retry に依存します。
- `MODBUS_MAX_QUEUED_BYTES` と `MODBUS_MAX_QUEUED_CHUNKS` は compile-time configuration です。値を増やすことは delivery guarantee
  ではなく、ESP32-C5 の memory 使用量も増やします。

## Command delivery と state

- Drive は直近32件の `{request_id, command, result}` を RAM に保持します。同じ ID / command の近接 retry は cached result を返し、
  movement を再実行しません。
- cache eviction 後の古い ID、または Drive reboot 後の retry は新規 command として実行されます。rover state、request cache、
  sensor sequence、last sample は reboot で失われます。
- Controller は起動ごとの random value から request ID range を開始しますが、永続 namespace や過去 boot との collision 検出は
  ありません。durable delivery と exactly-once execution は保証しません。
- Sensors sample request と Controller relay は idempotent な transaction ID を持ちません。timeout 後の自動 mission resume、partial
  progress の照合、再取得した sample の重複排除は未実装です。

## Failure detection と recovery

- 現在の AtomVM-to-AtomVM / alternative carrier 構成では remote PID に対する `Process.monitor/1` が `badarg` となるため、
  application readiness lease を使用します。
- default の heartbeat 30秒、lease 75秒は即時検出を目的としません。message delivery が lease より遅れると false positive が
  発生します。5秒 lease では実機で両 role の誤 expiry を確認しました。
- Controller は sensor-driven mission を同期的に実行します。mission command の reply 待ち中は readiness lease を評価しないため、
  remote outage の検出は command timeout または mission 終了後まで遅れます。
- Drive / Sensors の独立 reboot 後に distribution と application probe が復旧することは確認済みですが、進行中 mission の自動再開や
  rover state の reconciliation は行いません。
- peer session change で古い reader を閉じると、回復可能な場合でも AtomVM console に
  `{serial_read_error, closed}` の crash report が表示されます。

## 性能と用途

- shared half-duplex bus、polling、stop-and-wait、distribution framing により、direct UART distribution より latency が大きくなります。
  115,200 baud の短時間 application soak では両 remote の平均 RTT は約3.18秒でした。
- reply loss fault injection は application reply の破棄だけを再現します。RS485 cable fault、partial RTU frame、node power loss、
  simultaneous reboot と同じ failure modelではありません。
- physical actuator、real-time control、safety-critical control、production robot には使用しません。
