# ロードマップ

このサンプルは、Modbus RTU 上で genuine distributed Erlang を動かすという当初の目標を達成しています。現在は
experimental baseline を維持し、追加の測定または upstream AtomVM の変更によって根拠を強める段階です。

実行方法は [サンプル README](../README.md)、保証しない範囲は [既知の制約](limitations.md)、実測値は
[作業記録](worklog/README.md)、長期的な判断は [ADR](adr/README.md) を正とします。このページには達成済みの範囲と、
着手条件が明確な follow-up だけを残します。

## 現在地

| 領域 | 状態 | 確認済みの範囲 |
| --- | --- | --- |
| logical transport | 完了 | proprietary FC-100、双方向配送、順序、ACK、再送、重複抑止 |
| genuine distribution | 完了 | `serial_dist` handshake、remote process ping/pong、multi-chunk payload |
| session recovery | 完了 | client / server reboot、起動順序、active-transfer reboot |
| resource protection | 完了 | 8 KiB / 256 chunks、queue-full session rollover、idle marker coalescing |
| hardware baseline | 完了 | XIAO ESP32-C5 2 台、9,600 / 115,200 baud、512-byte soak、4 KiB traffic |
| application reuse | 実証済み | 仮想ロボット example が shared client 経由で 2 つの logical stream を利用 |
| package boundary | 決定済み | carrier は AVModbus core へ移さず、experimental example 内で保守 |
| AtomVM setup retry | upstream 待ち | local patch と実機 A/B は完了、公式 release では未確認 |

`hello_atomvm_modbus_disterl` 自体は 2-node の最小実験を維持します。3-device / 3-node application への再利用結果は
[仮想ロボットのロードマップ](../../hello_atomvm_modbus_robot/docs/roadmap.md) と
[実機 worklog](../../hello_atomvm_modbus_robot/docs/worklog/README.md) で管理します。

## 達成済みの範囲

- [x] FC-100 上に stop-and-wait の logical byte stream を構成する
- [x] virtual UART から AtomVM の既存 `serial_dist` を利用する
- [x] outgoing queue を payload byte 数と chunk 数で制限する
- [x] queue-full と peer session change を明示的な stream boundary として扱う
- [x] Client-first / Server-first startup、独立 reboot、active-transfer reboot を確認する
- [x] 512-byte soak、4 KiB traffic、limited ACK loss を実機で確認する
- [x] AtomVM の early setup failure を再現し、local fix を新旧 boot library で A/B 確認する
- [x] carrier を example に維持する判断と制約を ADR・limitations・worklog に記録する
- [x] AVModbus core を変更せず、別 example の 3-node application から再利用する

この一覧を experimental baseline の完了条件とします。新しい測定値はここへ追加せず、worklog と limitations を更新します。

## 優先する follow-up

| 優先度 | 調査 | 完了の根拠 |
| --- | --- | --- |
| 1 | AtomVM の setup PID 修正を upstream へ提案する | upstream PR または issue と、取り込み release での failure-injection 再試験 |
| 2 | default 9,600 baud で数時間の soak を行う | queue、free heap、timeout 数の時系列と停止条件を worklog へ記録 |
| 3 | ACK loss と通信断・復旧を反復する | memory stability と session rollover の収束を複数 run で確認 |
| 4 | 16-bit sequence wraparound を実機で通過する | wraparound 前後の順序、重複、queue 状態を記録 |
| 5 | 115,200 baud の 4 KiB transfer を反復する | 連続 traffic と active-transfer reboot を複数 run で完了 |

follow-up は production readiness の約束ではありません。開始前に成功条件、停止条件、測定項目を決め、結果は
`docs/worklog/` へ追加します。単発の成功を一般的な保証へ広げません。

## 維持する判断

- proprietary FC-100 carrier を AVModbus の一般 API にしない
- example 外の独立 consumer と stable lifecycle contract が得られるまで package へ分離しない
- 現在の 2-node baseline では virtual UART adapter を維持し、専用 `modbus_dist` carrier を実装しない
- queue 上限を厳密な VM heap 上限または application backpressure とは表現しない
- session recovery を durable delivery または exactly-once semantics とは表現しない

package boundary は [ADR 0012](adr/0012-keep-the-carrier-in-the-example.md)、virtual UART は
[ADR 0003](adr/0003-adapt-serial-dist-with-a-virtual-uart.md) に記録しています。これらの前提が変わる場合は、新しい ADR で判断を
置き換えます。

## 対象外

- production-ready distributed Erlang transport
- このサンプル単体での 3-node 以上の multidrop scheduling と routing
- dynamic node discovery
- full Erlang/OTP distribution compatibility
- physical actuator または safety-critical control
- 実測根拠のない performance optimization
- 実験固有の protocol を理由にした AVModbus core の変更
