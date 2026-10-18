# ドキュメント

この実験のドキュメントは、現在の利用方法、計画、設計判断、検証記録に分けています。

## 利用方法

- [サンプル README](../README.md) — host simulation、Stage 1 実機実行、座標規則、command、目標構成

現在動く機能と再現手順はサンプル README を正とします。

## 設計資料

- [ロードマップ](roadmap.md) — Stage ごとの完了条件と未着手の調査項目
- [設計判断記録](adr/README.md) — 長期的に維持する application 設計の判断

## 検証記録

- [作業記録](worklog/README.md) — host test、実機試験、障害調査の時系列記録

## 更新方針

- 本文は日本語を基本とし、API 名、protocol 名、正式な技術用語は必要以上に翻訳しません。
- 現在の使い方を worklog に複製せず、サンプル README へ集約します。
- 実測値には日付、環境、条件、再現 command を添え、確認済みの範囲と一般的な保証を区別します。
- 長期的な判断を変更する場合は、既存 ADR を書き換えず、新しい ADR で置き換えます。
- Stage を完了したら roadmap と worklog を同時に更新します。
