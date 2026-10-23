# Stage 1 実行中のDrive再起動 — 2026-10-18

## 目的

movement command が Drive で実行された後、reply が Controller に届く前に Drive board を reset し、次を確認する。

- FC-100 session と Erlang distribution が再接続できるか
- Controller が同じ request ID で retry できるか
- volatile rover state と request cache を失った場合の application behavior
- Controller が誤った final state を成功として扱わないか

hardware と UART 条件は [通常 mission の実機記録](2026-10-18-stage-1-two-board-mission.md) と同じである。

## 最終状態の検証

試験前に `RobotSim.Controller.demo/2` を変更し、最後の `:status` reply を
`RobotSim.expected_demo_state/0` と比較するようにした。不一致は次の形式で返す。

```elixir
{:error, {:unexpected_final_state, rover}}
```

初期位置を 10 mm ずらした host test を追加し、誤った final state を拒否することを確認した。

## 障害注入

Drive を先に起動し、Controller を通常どおり起動した。Drive monitor の `tio` script は request 2 の log を待ち、
state transition の直後に RTS を toggle して board を reset した。

```text
expect("request_id=2", 60000)
set{DTR=high,RTS=low}
msleep(100)
set{RTS=toggle}
```

対象 command は `{:turn, :right, 90}` である。reset 前の Drive state は
`{x_mm: 100, y_mm: 0, heading_deg: 90}` まで更新されていたが、その result は Controller に届かなかった。

## 結果

Controller は peer session change を検出した。旧 `serial_dist` reader は `{:serial_read_error, :closed}` で終了し、
60 秒の application timeout 後に同じ request ID 2 を再送した。

```text
modbus_robot_controller: request_id=2 timed out; retrying
modbus_robot_controller: sending request_id=2 attempt=2 command={:turn, :right, 90}
```

新しい Drive session と distribution connection は確立され、retry は remote Drive process に届いた。ただし reboot 後の
Drive は初期 state と空の request cache で起動するため、request 2 を原点で再実行した。

```text
modbus_robot_drive: request_id=2 command={:turn, :right, 90} result={:ok, %{x_mm: 0, y_mm: 0, heading_deg: 90, ...}}
modbus_robot_drive: request_id=3 command={:forward, 50} result={:ok, %{x_mm: 0, y_mm: 50, heading_deg: 90, ...}}
```

Controller は mission を最後まで進めた後、期待値 `(100, 50, 90°)` と実測値 `(0, 50, 90°)` の不一致を検出した。

```text
modbus_robot: reference mission returned {:error, {:unexpected_final_state, %{x_mm: 0, y_mm: 50, heading_deg: 90, ...}}}
modbus_robot: mission failed {:unexpected_final_state, %{x_mm: 0, y_mm: 50, heading_deg: 90, ...}}
```

## 結論

- FC-100 session-aware carrier と AtomVM distribution は独立した Drive reboot 後に再接続した。
- application timeout / retry は reconnect 後も機能した。
- request ID cache は同一 Drive process 内の lost reply には有効だが、reboot をまたぐ重複排除にはならない。
- rover state も volatile であるため、残りの mission を継続しても正しい最終状態にはならない。
- Controller の final-state verification により silent success は防止できた。

Stage 1 では失敗を検出して mission を停止できることまでを範囲とする。自動回復には、Drive state / completed request の
永続化、Controller が保持する mission state からの reconciliation、または absolute / idempotent command model の設計が
必要になる。これらは Stage 4 で比較する。
