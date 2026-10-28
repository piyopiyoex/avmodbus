# 検証結果

Modbus RTU 上の distributed Erlang 実験で、今後の比較に必要な条件と結果をまとめます。
個別の操作ログは Git の履歴、現在の実行方法は [サンプル README](../../README.md)、
設計判断は [ADR](../adr/README.md) を参照してください。

## 検証環境

| 項目 | 条件 |
| --- | --- |
| 検証期間 | 2026-10-15〜16 |
| Device | Seeed Studio XIAO ESP32-C5 × 2 |
| Transceiver | HW-519 × 2、2-wire RS485 |
| Runtime | AtomVM `v0.7.0-beta.0+git.8d3e051` |
| Setup retry | boot library `release-0.7` `4ef13692` + local patch `735841ba` |
| Transport | proprietary FC-100、Client poll 20 ms |
| Stream | 96-byte operating chunk、8 KiB / 256 chunks queue |

## 達成したこと

- FC-100 request / response 上の双方向 byte stream、sequence / ACK、再送、重複抑止
- virtual UART を介した genuine `serial_dist` handshake と remote process messaging
- client / server の独立 reboot、session resynchronization、起動順序の違いからの復旧
- queue-full 時の session rollover と、idle sync marker の coalescing
- host test で 64 KiB byte stream、16-bit sequence wraparound、RTU fault injection

## Payload と latency

| 条件 | 結果 |
| --- | --- |
| 9,600 baud、zero-byte ping / pong | RTT 1.326 s（single run） |
| 115,200 baud、zero-byte ping / pong | RTT 0.890 s（single run） |
| 9,600 baud、512-byte × 30 | 30 / 30、RTT 5.250 / 5.425 / 7.477 s（min / avg / max） |
| 115,200 baud、512-byte × 30 | 30 / 30、RTT 3.245 / 3.311 / 4.923 s |
| 9,600 baud、4 KiB × 3 | 3 / 3、RTT 33.817 / 34.743 / 36.594 s |
| 115,200 baud、4 KiB × 1 | 成功、RTT 22.617 s |

いずれも direct UART より遅く、Modbus polling、half-duplex turnaround、fragmentation、stop-and-wait の
影響を含みます。単発または短時間の結果であり、長期性能の保証ではありません。

## Recovery と fault injection

| Scenario | 結果 |
| --- | --- |
| Client-first / Server-first startup | readiness gate 後に handshake と ping / pong が成立 |
| Client / Server の独立 reboot | peer session change を検出して再接続 |
| 4 KiB transfer 中の Server reboot | 1回の pong timeout 後、application retry で再送・検証 |
| 4 KiB write の response 3回消失 | duplicate delivery なしで queue を drain |
| 8 KiB queue-full probe | oversize ping は timeout、通常 payload の retry で再接続 |
| readiness 後の handshake response fault | local AtomVM setup retry patch では復旧、公式 beta.0 では未確認 |

recovery は session 内の durable delivery や exactly-once を保証しません。queue 済みまたは in-flight の
data は session rollover で破棄され、application retry に依存します。

## 採用した判断

- carrier は AVModbus core へ移さず、この experimental example 内で保守する
- 2-node baseline では既存 `serial_dist` と virtual UART を維持する
- wire protocol の最大値 232 bytes と、実機で安定した 96-byte chunk を区別する
- queue 上限を VM 全体の memory 上限とは表現しない

現在の制約は [既知の制約](../limitations.md)、構成は [アーキテクチャ](../architecture.md)、
今後の条件は [ロードマップ](../roadmap.md) を参照してください。
