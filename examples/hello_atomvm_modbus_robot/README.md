# Modbus RTU distributed Erlang で動かす仮想ロボット（実験）

AtomVM の distributed Erlang over Modbus RTU を、通信確認だけでなく分散 application に利用するための
独立した実験用 Mix project です。ロボットは software 上で再現するため、motor、sensor、車体は必要ありません。

現在は **Stage 0: host 上の rover simulation** まで実装しています。Modbus RTU、Erlang distribution、AtomVM、
実機はまだ使用しません。既存の
[`hello_atomvm_modbus_disterl`](../hello_atomvm_modbus_disterl/README.md) と AVModbus core に変更を加えず、
移動規則と mission を先に固定します。

## 現在できること

- 整数 millimetre 単位の X/Y 座標と 4 方向の heading を保持する
- 指定距離だけ前進する
- 90° 単位で左右へ旋回する
- 現在の rover state を取得する
- 同じ初期状態と command 列から常に同じ結果を得る
- deterministic demonstration mission を host test で検証する

今後の Stage 1–4 と完了条件は [ロードマップ](docs/roadmap.md) を参照してください。

## Host で実行する

repository root から次を実行します。

```sh
cd examples/hello_atomvm_modbus_robot
mise install
mix format --check-formatted
mix test
mix run -e 'IO.inspect(RobotSim.demo())'
```

最後の command は次を出力します。

```elixir
{:ok, %RobotSim.Rover{x_mm: 100, y_mm: 50, heading_deg: 90}}
```

## 座標と heading

初期位置を `(0, 0)`、初期 heading を `0°` とします。`0°` は `+X` 方向です。heading は右旋回、つまり
clockwise に増加します。この規則では `90°` が `+Y` 方向です。

| heading | 前進時に変化する座標 |
| ---: | --- |
| `0°` | `x += distance` |
| `90°` | `y += distance` |
| `180°` | `x -= distance` |
| `270°` | `y -= distance` |

これは地理上の方位角や、角度が counterclockwise に増える通常の Cartesian plane を表す規則ではありません。
reference mission の「右へ 90° 旋回した後に `+Y` へ進む」という期待値を曖昧なく表すための規則です。
判断理由は [ADR 0001](docs/adr/0001-use-clockwise-heading-from-positive-x.md) に記録しています。

## Command

`RobotSim.Rover.execute/2` は rover state と command を受け取り、新しい state を返す pure function です。

| command | 意味 |
| --- | --- |
| `{:forward, distance_mm}` | 正の整数 millimetre だけ前進する |
| `{:turn, :right, degrees}` | 90° の倍数だけ右旋回する |
| `{:turn, :left, degrees}` | 90° の倍数だけ左旋回する |
| `:status` | state を変更せず現在値を返す |

不正な command は `{:error, :invalid_command}` を返します。現段階には command ID、retry、deduplication、
時間経過、速度、battery、obstacle はありません。

## Reference mission

```text
開始: (0, 0), heading 0°

100 mm 前進
右へ 90° 旋回
50 mm 前進

結果: (100, 50), heading 90°
```

Elixir では次の command 列です。

```elixir
[
  {:forward, 100},
  {:turn, :right, 90},
  {:forward, 50}
]
```

## 目標アーキテクチャ

```text
  controller@modbus.local       Modbus RTU Client / bus owner
            |
      shared RS485 bus
       /           \
 drive@modbus.local       sensors@modbus.local
  Server Unit 1             Server Unit 2
  virtual movement          virtual sensors
```

最初の実機 milestone では `controller` と `drive` の 2 node だけを使います。3 台目は、standard Modbus RTU の
multidrop と、1 本の UART 上に複数の独立した distribution stream を構成できるかを別々に検証してから追加します。
図は目標であり、現在サポートしている topology ではありません。

## 境界

- simulation logic と transport / process lifecycle を分離する
- AVModbus core と既存の distributed Erlang example を変更しない
- Stage 1 へ進む前に carrier の再利用境界を判断し、大量の source copy を避ける
- automatic retry の前に command ID と重複実行防止を設計する
- physical actuator、real-time control、safety-critical control を対象にしない

資料の一覧と更新方針は [docs/README.md](docs/README.md) にあります。
