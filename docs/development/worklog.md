# 開発記録

今後の判断に必要な milestone と release candidate の結果だけを残します。細かな実装履歴は Git、
設計判断は [ADR](../adr/README.md)、測定値は [リソース計測](resource-measurements.md) を参照してください。

## 主な milestone

| 日付 | 結果 |
| --- | --- |
| 2026-10-07〜09 | 既存の実験コードから AVModbus を分離し、RTU・ASCII・TCP の Client / Server と Supervisor 対応を実装 |
| 2026-10-10〜14 | RS485 実機通信、memory 計測、TCP リソース調査、外部実装との相互運用 CI を整備 |
| 2026-10-12〜13 | UART の継続受信、Serial Transport、bounded queue、timeout 管理を強化 |
| 2026-10-15〜16 | custom FC-100 carrier を使う distributed Erlang を example 内で実機検証 |
| 2026-10-28 | `v0.1.0` Hex release candidate を検証 |

## v0.1.0 release candidate

2026-10-28 に次を確認しました。

- `mix format --check-formatted`、Python 補助 script 3 tests、ExUnit 228 tests が成功
- coverage 84.75%（threshold 80%）、`mix docs --warnings-as-errors` が成功
- 通常、workflow probe、resource probe の `mix atomvm.check` が成功
- production AVM は 147,536 / 147,736 bytes
- 約 96 KiB の Hex package を build・展開し、別の Mix application から compile できた
- 展開 package で RTU encode / decode が成功
- `mix hex.publish --dry-run --yes` が成功し、実際には公開されていないことを確認
- Hex user は `mnishiguchi`、package 名 `avmodbus` は未登録

実 RS485 workflow は Controller を Client、Drive を Unit ID `1` の Server とし、従来 Unit ID `2` に
使用した Sensors も共有 bus へ接続した状態で実行しました。

| 項目 | 条件・結果 |
| --- | --- |
| 機器 | XIAO ESP32-C5 × 3、HW-519 × 3 |
| Runtime | Controller / Drive: AtomVM `0.7.0-beta.1+git.a1069573` |
| 通信 | RTU、9,600 baud、8N1、GPIO23 TX、GPIO24 RX、gap 20 ms |
| Workflow | 20 種類 × 3 cycles、60 / 60 requests 成功 |
| Timing | request 136 / 165 / 218 ms（min / average / max）、総時間 9,918 ms |
| Bus | response-to-next-write 最小 43 ms、broadcast turnaround 136 ms |

`a1069573` は AtomVM `18b35870` に distribution tick 用の local patch を加えた版です。
patch は通常の Modbus RTU workflow では使用しません。欠損、timeout、想定外の応答、
3台目を接続したことによる干渉は観測しませんでした。

release PR の `test` と `interoperability` が成功し、`pymodbus` / `libmodbus` は
seed `12345` / `54321` の両方で確認しました。publish、tag push、GitHub Release 公開は
レビュー後に手動で行います。

## 関連資料

- [実機での追加検証](hardware-tests.md)
- [リソース計測](resource-measurements.md)
- [TCP リソース上限の調査](atomvm-tcp-investigation.md)
- [互換性表](../compatibility.md)
- [実験用 example](../README.md#実験)
