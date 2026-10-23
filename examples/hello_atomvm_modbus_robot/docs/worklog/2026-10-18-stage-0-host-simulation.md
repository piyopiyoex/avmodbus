# Stage 0 ホスト専用ローバーシミュレーション — 2026-10-18

## 目的

Modbus RTU や Erlang distribution を導入する前に、virtual rover の state transition、座標規則、reference mission を
host 上で固定する。

## 環境

- Elixir 1.19.6
- Erlang/OTP 28
- application: `examples/hello_atomvm_modbus_robot`
- hardware: 未使用
- Modbus / AtomVM / Erlang distribution: 未使用

## 実行

```sh
cd examples/hello_atomvm_modbus_robot
mise exec -- mix format --check-formatted
mise exec -- mix test
mise exec -- mix run -e 'IO.inspect(RobotSim.demo())'
```

## 結果

- unit test: 7 tests、0 failures
- reference mission: `{:ok, %RobotSim.Rover{x_mm: 100, y_mm: 50, heading_deg: 90}}`
- invalid distance、45° turn、unknown direction、unknown command を拒否した
- 同じ mission と initial state が同じ final state を返すことを確認した

## 判断

Stage 0 の完了条件を満たした。Stage 1 では rover の pure state transition を変更せず、process ownership、
command ID、reply、timeout、deduplication を別の layer として追加する。
