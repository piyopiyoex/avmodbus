# 設計判断記録

この実験で長期的に維持する設計判断を記録します。現在の利用方法は
[サンプル README](../../README.md)、計画は [ロードマップ](../roadmap.md)、検証結果は
[作業記録](../worklog/README.md) を正とします。

## 追加と更新

- ファイル名は `NNNN-lowercase-kebab-case.md` とし、番号は連番にします。
- 背景、採用する方針、影響を簡潔に記録します。
- 一時的な作業手順や測定 log は `docs/worklog/` に置きます。
- 判断を変更するときは新しい ADR を追加し、置き換え関係を記録します。
- ADR を追加したら、この一覧にもリンクを追加します。

## 一覧

- [0001: +X から clockwise に増える heading を使う](0001-use-clockwise-heading-from-positive-x.md)
- [0002: request ID で command retry を重複排除する](0002-deduplicate-retries-with-request-ids.md)
- [0003: 既存 example の experimental carrier を再利用する](0003-reuse-the-existing-experimental-carrier.md)
- [0004: 3-node distribution より先に standard multidrop を検証する](0004-validate-standard-multidrop-before-distribution.md)
- [0005: 1 個の Modbus Client を複数 distribution stream で共有する](0005-share-one-client-across-distribution-streams.md)
