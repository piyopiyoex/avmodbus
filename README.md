# AVModbus

AVModbus は、**AtomVM で Modbus 通信を扱うための Elixir ライブラリ**です。
Modbus RTU・ASCII・TCP に対応し、データを読み取る Client と、要求に応答する Server の両方を作れます。

たとえば、ESP32-C5 と RS485 モジュールを使ってセンサーの値を読んだり、
ほかの機器から読み取れる Holding Register を用意したりできます。

## インストール

利用側の `mix.exs` に次の依存関係を追加します。

```elixir
{:avmodbus, "~> 0.1.0"}
```

AtomVM 向けのファームウェアを作る場合は、AtomVM 側の依存関係も必要です。
詳細は [はじめ方](docs/getting-started.md) を参照してください。

## まず動かしてみる

初めて Modbus を使う場合は、次の順に読むと進めやすいです。

1. [Modbus の基礎](docs/modbus-basics.md) — RS485 との関係や基本用語
2. [はじめ方](docs/getting-started.md) — ライブラリの追加と読み書き
3. [XIAO ESP32-C5 実機チュートリアル](examples/hello_atomvm_modbus/README.md) — 2 台の基板で RS485 通信

## 対応している機能

- Modbus RTU・ASCII・TCP の Client / Server
- Coil・Discrete Input・Input Register・Holding Register の読み取りと、書き込み可能な領域への書き込み
- 主な標準 Function Code、タイムアウト、再接続、読み取り処理のリトライ
- AtomVM UART と、ほかの通信手段に差し替えられる Serial Transport
- Elixir の Supervisor からの起動

対応状況と実機で確認した構成は [互換性表](docs/compatibility.md) に記録しています。

## Client の例

Unit ID `1` の Holding Register を、アドレス `0` から 2 個読み取ります。

```elixir
{:ok, client} = AVModbus.Client.start_link(transport: :rtu, timeout: 1_000)

{:ok, values} = AVModbus.Client.read_holding_registers(client, 1, 0, 2)
IO.inspect(values, label: "Holding Registers")
```

RTU を使う場合は、先に UART のピンや通信速度を設定してください。
詳しい設定方法は [はじめ方](docs/getting-started.md) にあります。

## Server の例

```elixir
{:ok, memory} = AVModbus.Memory.start_link()
:ok = AVModbus.Memory.put(memory, :holding_register, 0, [123, 456])

{:ok, server} =
  AVModbus.Server.start_link(
    handler: {AVModbus.Memory, memory},
    transport: :rtu,
    units: [1]
  )
```

この例でも、実機では UART 設定が必要です。

## 実験用サンプル

AVModbus の公開 API を利用した、次の実験も収録しています。

- [Modbus RTU 上の distributed Erlang](https://github.com/piyopiyoex/avmodbus/tree/v0.1.0/examples/hello_atomvm_modbus_disterl) — 2 台の ESP32-C5 間で `serial_dist` を動かす実験
- [distributed Erlang 仮想ロボット](https://github.com/piyopiyoex/avmodbus/tree/v0.1.0/examples/hello_atomvm_modbus_robot) — 3 台の ESP32-C5 と共有 RS485 バスを使う分散アプリケーション

どちらも本番用途の機能ではなく、Hex パッケージには含めません。構成、実測結果、既知の制約は各サンプルの資料を参照してください。

## 開発に参加する

```sh
mise install
mix deps.get
mix format --check-formatted
mix test
```

設計や検証結果を調べる場合は、次の資料を参照してください。

- [ドキュメント一覧と更新方針](https://github.com/piyopiyoex/avmodbus/blob/v0.1.0/docs/README.md) — 資料の分類とメンテナンス方法
- [開発者ガイド](docs/development.md) — テストと高度な使い方
- [アーキテクチャ](docs/architecture.md) — 内部構造と設計方針
- [開発資料](https://github.com/piyopiyoex/avmodbus/blob/v0.1.0/docs/development/README.md) /
  [設計判断](https://github.com/piyopiyoex/avmodbus/blob/v0.1.0/docs/adr/README.md) — 検証結果と判断理由
- [リリース前チェックリスト](https://github.com/piyopiyoex/avmodbus/blob/v0.1.0/docs/development/release-checklist.md)

## 動作環境と注意点

実機では、XIAO ESP32-C5、HW-519 RS485 モジュール、AtomVM `release-0.7` 系で確認しています。
正確なバージョンと試験内容は [互換性表](docs/compatibility.md) を参照してください。
ライブラリ自体に実行時依存パッケージはありません。

Modbus TCP の暗号化・相互認証には未対応です。暗号化なしに自動で切り替わることはありませんが、
**TCP Server は信頼できるネットワーク内で使用してください**。
また、ESP32-C5 の TCP 接続数には実機で確認した範囲があります。
詳細は
[既知の制約](https://github.com/piyopiyoex/avmodbus/blob/v0.1.0/docs/limitations.md)
を参照してください。

## ライセンス

Apache-2.0
