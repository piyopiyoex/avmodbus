# リリース前チェックリスト

Hex への初回公開は `v0.1.0` を対象とします。実施した項目だけをチェックし、
コマンド結果と対象コミットを記録してください。詳細な公開手順は [RELEASE.md](../../RELEASE.md) を参照します。

## API とドキュメント

- [x] README・Getting Started・ExDoc の引数、戻り値、コード例が実装と一致する
- [x] 同期・非同期要求、timeout、queue 上限、TCP の `max_buffer` の説明が正確である
- [x] TLS 非対応・ESP32-C5 のリソース制限・実機検証範囲を明示している
- [x] `CHANGELOG.md` の `0.1.0` の内容と `mix.exs` の version が一致する
- [x] README / Getting Started に未公開を前提とする表記が残っていない
- [x] バージョン付き ExDoc のソースリンクが `v0.1.0` タグを指す
- [x] Hex 名 `avmodbus` と公開先アカウント・初期オーナーを確認する

## 検証

```sh
mix deps.get
mix format --check-formatted
mix test --cover
python3 -m unittest discover -s scripts -p 'test_*.py'
mix docs --warnings-as-errors
```

- [x] 上記がすべて成功する
- [x] リリース対象コミットで GitHub Actions の `test` と `interoperability` が成功する
- [x] `pymodbus` / `libmodbus` の相互運用テストが seed `12345` と `54321` で成功する
- [x] 対象 AtomVM でサンプルの `mix atomvm.check` とサイズ測定が成功する
- [x] RTU / RS485 の基本読み書きを実機で再確認し、firmware・配線・設定を記録する
- [x] [互換性表](../compatibility.md)に検証済みの構成を反映する

## Hex パッケージ

```sh
mix hex.build
mix hex.build --unpack --output tmp/hex-package
mix hex.publish --dry-run --yes
```

- [x] `tmp/hex-package` に `lib/`、`docs/`、`mix.exs`、`README.md`、`RELEASE.md`、`LICENSE` が含まれる
- [x] `examples/hello_atomvm_modbus/README.md` が含まれる
- [x] テスト・ビルド成果物・distributed Erlang / robot の実験コードと worklog は含まれない
- [x] `docs/development/worklog.md` は AVModbus core の設計・検証記録として含まれる
- [x] パッケージ内の README や ExDoc にリンク切れがない
- [x] 別アプリから展開済み package を `path:` 参照して取得・コンパイルできる
- [x] `mix hex.publish --dry-run --yes` が成功する（実際の公開は行わない）

## 公開時・公開後

- [ ] リリース候補を承認して `main` にマージし、タグの対象コミットを確定する
- [ ] Hex の認証ユーザーと publish 権限を確認する
- [ ] `v0.1.0` 注釈付きタグを対象コミットに作成する
- [ ] 対話的な `mix hex.publish` を行い、Hex と HexDocs の公開結果を確認する
- [ ] タグを push し、CHANGELOG に基づく GitHub Release を公開する
- [ ] 公開後、別アプリから `{:avmodbus, "~> 0.1.0"}` を取得・コンパイルする
- [ ] 公開後の修正は既存 version や tag を差し替えず、patch release で行う

チェックリストの作成・実行だけでは Hex への公開は行いません。
