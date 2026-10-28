# AtomVM ESP32-C5 の TCP リソース上限

AVModbus の bounded queue と cleanup を検証中に確認した、AtomVM runtime 側の制約をまとめます。
AVModbus の不具合、または全 ESP32-C5 に共通する上限とは断定しません。

## 結論

XIAO ESP32-C5 と AtomVM `v0.7.0-beta.0+git.8d3e051` では、1〜4 loopback connections の
resource probe が3 cycles 完走し、process 数と free heap が許容範囲へ回復しました。

確認済み範囲を超えて socket 負荷を増やすと、回復可能な `:emfile` や `:enomem` が Elixir へ返る前に、
timer manager の timeout、application の終了、または native abort が発生しました。
runtime が error を返さない状態を AVModbus だけで回復することはできません。

このため、sample の `MODBUS_RESOURCE_PROBE_CONNECTIONS` は `1..4` に制限します。
4 connections は probe で確認した最大値であり、一般的な安全上限ではありません。

## 確認環境

- Board: Seeed Studio XIAO ESP32-C5
- Runtime: AtomVM `v0.7.0-beta.0+git.8d3e051`
- Transport: ESP32 socket driver、TCP loopback `127.0.0.1`
- Application: `examples/hello_atomvm_modbus` の resource probe

数値は [リソース計測](resource-measurements.md#tcp-loopback) を参照してください。

## 確認できたこと

通常の probe は network stack を warm-up してから4 managed Clients を作り、各 Client で3 requests と
想定どおりの `:queue_full` を確認します。全 measured cycles で次を確認しました。

- request が完了する
- connection と handler process が終了する
- process 数が baseline へ戻る
- free heap が 32 KiB recovery bound 内へ戻る

Linux では file descriptor 上限を下げた optional test により、runtime が `:emfile` を返す場合に
Client が reconnect し、Server も descriptor 解放後に起動できることを確認しています。

```sh
RESOURCE_EXHAUSTION_TEST=true mix test \
  test/avmodbus/tcp_resource_exhaustion_test.exs
```

## 未解決の範囲

確認済み範囲を超える一時的な diagnostic build では、次を観測しました。

- 8 managed Clients の起動後に timer manager が timeout
- sequential socket 負荷で USB console が応答しなくなる
- low-level socket variant で symbol 未解決の native abort

いずれも `:emfile`、`:enfile`、`:enobufs`、`:enomem`、`:system_limit` は Elixir へ返りませんでした。
対応する symbol 付き ELF がないため、native abort の原因は特定していません。

複数 socket の終了時には、`netconn_events` または `event_queue` への enqueue failure が表示されることが
あります。この warning は正常に cleanup できた probe でも発生するため、warning だけを memory leak の
証拠とは扱いません。

## 安全な再現方法

```sh
cd examples/hello_atomvm_modbus
MIX_ENV=prod mix clean
MODBUS_RESOURCE_PROBE=true MIX_ENV=prod mix atomvm.packbeam
MODBUS_RESOURCE_PROBE=true MIX_ENV=prod \
  mix atomvm.esp32.flash --port /dev/ttyACM0
mix atomvm.esp32.monitor --port /dev/ttyACM0
```

- まず既定の4 connectionsで正常系を確認する
- 通常 example の guard は緩めない
- hard-limit 調査は予備 board と一時 build を使い、電源再投入が必要になる前提で行う
- runtime image と対応する ELF / map、serial log を保存する

## 再評価する条件

AtomVM の socket、event queue、timer path が変わった場合に再評価します。

1. 同じ board と workload で bounded probe を実行する
2. hard-limit 時に回復可能な error が Elixir へ返るか確認する
3. error 後に resource を解放し、reboot せず request を再開できるか確認する
4. 新しい結果を [リソース計測](resource-measurements.md) と [既知の制約](../limitations.md) に反映する
