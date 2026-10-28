# 既知の制約

この example は 2-node proof of concept です。実測条件は [検証結果](worklog/README.md) を参照してください。

## 構成

- single Modbus Client、single Unit ID、2 nodes を対象とする
- Server は自発的に bus を駆動できず、Client の poll latency に依存する
- multidrop scheduling、routing、dynamic discovery は提供しない
- proprietary FC-100 protocol は一般の Modbus device と互換ではない

## Buffer と delivery

- outgoing queue は既定 8 KiB / 256 chunks。payload の合計であり、VM heap 全体の上限ではない
- 16 KiB application payload は queue check 前の distribution framing で OOM になった
- queue-full または peer session change は stream boundary とし、queue 済み / in-flight data を破棄する
- sequence / ACK は session 内の順序と重複抑止を提供するが、durable delivery や exactly-once ではない
- 16-bit sequence wraparound は host test 済みで、実機の長時間通過試験は未実施
- session ID は起動時の 32-bit random value で、永続的な node identity ではない

## AtomVM distribution

- distribution setup timeout は 7秒固定。1,000 ms poll では失敗し、20 ms を既定値として検証した
- readiness gate は initial setup 前の transport response を確認するだけで、任意の half-open state を回復しない
- readiness 後の setup retry は local AtomVM patch で A/B 検証したが、公式 beta.0 には含まれない
- peer reboot 時は意図した `{serial_read_error, closed}` の crash report が console に表示される

## Hardware と性能

- wire protocol は最大 232-byte payload を許容するが、XIAO / HW-519 では上限付近が不安定だった
- 実機 default は 96-byte chunk（RTU frame 113 bytes）、9,600 baud、20 ms poll
- 512-byte と 4 KiB payload は短時間試験済み。長時間 ACK loss、連続 115,200 baud、実機 sequence wraparound は未検証
- latency は direct UART より大幅に高く、real-time または safety-critical control には適さない

## Support boundary

carrier、virtual UART、recovery policy は AVModbus の public API または production support の対象外です。
専用 `modbus_dist` は現在の 2-node 構成では必要ありませんでしたが、ほかの topology へ一般化できるとは限りません。
