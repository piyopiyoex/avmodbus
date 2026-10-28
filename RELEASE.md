# AVModbus リリース手順

`v0.1.0` の Hex 公開手順。作業は `main` の最新コミットを起点に行います。
技術的な確認項目は [リリース前チェックリスト](docs/development/release-checklist.md) を正とします。

## 1. リリース候補を確認する

1. `mix.exs` の version (`0.1.0`)、`CHANGELOG.md`、公開対象の API を確認する。
2. README と Getting Started が Hex からの導入を現在形で案内し、未公開を前提とする表記が残っていないことを確認する。
3. `mix hex.info avmodbus` で名前の利用状況を確認する。
4. `mix hex.user whoami` で公開アカウントを確認する。`v0.1.0` は個人 owner `mnishiguchi` で公開し、organization は選択しない。
5. [リリース前チェックリスト](docs/development/release-checklist.md) の API・テスト・実機確認を完了し、対象コミットの CI が成功していることを確認する。

## 2. 配布物を確認する

```sh
mix deps.get
mix docs --warnings-as-errors
mix hex.build
mix hex.build --unpack --output tmp/hex-package
mix hex.publish --dry-run --yes
```

`--yes` は dry-run 時の owner 選択を含む確認 prompt を省略するために使う。
`--dry-run` があるため package や docs は公開されない。
実際の公開では `--yes` を使わず、表示内容と owner を対話的に確認する。

`tmp/hex-package/` 内の `lib/`、`docs/`、`mix.exs`、`README.md`、`RELEASE.md`、`LICENSE`、
`examples/hello_atomvm_modbus/README.md` を確認する。
分散 Erlang・仮想ロボットの実験コード、各 example の worklog、テスト、ビルド成果物は配布しない。
`docs/development/worklog.md` は AVModbus core の設計・検証記録として配布対象に含める。

展開した package を、別の新規 Mix アプリから `path:` dependency として参照し、
`mix deps.get` と `mix compile --warnings-as-errors` を実行する。
例: `{:avmodbus, path: "/absolute/path/to/tmp/hex-package"}`。
この試験は、まだ公開されていない `v0.1.0` に対して実施できる。

## 3. 公開する（手動操作）

1. リリース候補の変更を `main` にマージし、ローカルの `main` を更新する。
2. `mix hex.user whoami` で `mnishiguchi` を確認する。owner 選択が表示された場合は `[1] Yourself` を選び、organization を選択しない。
3. `git tag -a v0.1.0 -m "AVModbus v0.1.0"` で対象コミットに注釈付きタグを作成する。
4. `mix hex.publish` を対話的に実行し、表示されたファイル一覧などを確認してから承認する。
5. Hex の package と `https://hexdocs.pm/avmodbus/0.1.0/` を確認する。
6. `git push origin v0.1.0` でタグを push し、GitHub Release を作成する。本文は `CHANGELOG.md` の `0.1.0` に合わせる。
7. 別アプリで `{:avmodbus, "~> 0.1.0"}` を指定して `mix deps.get` と `mix compile` を確認する。

ドキュメントは通常の `mix hex.publish` で同時に公開される。
`mix.exs` の ExDoc 依存は `only: :dev` なので、`MIX_ENV=docs` は使用しない。
公開操作をスクリプトで自動実行せず、認証・公開内容を人が確認する。

## 4. 公開後に問題が見つかった場合

公開済み version の内容や Git tag は差し替えない。通常の不具合は修正 commit を追加し、
`0.1.1` 以降の patch release として公開する。
Hex の revert は、誤った package や機密情報を公開した場合など、公開継続が不適切な緊急時だけ検討する。
revert 後も同じ tag を移動して履歴を書き換えず、原因と対応を CHANGELOG と GitHub Release に記録する。

## 5. 範囲

Hex の対象は `lib/avmodbus/` の汎用 Modbus ライブラリ。
`examples/hello_atomvm_modbus_disterl/` と `examples/hello_atomvm_modbus_robot/` は
GitHub 上の実験用サンプルであり、Hex package の公開 API や production support には含めない。
