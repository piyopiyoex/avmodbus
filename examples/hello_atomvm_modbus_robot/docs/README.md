# ドキュメント

この実験のドキュメントは、現在の利用方法、計画、設計判断、検証記録に分けています。

## 利用方法

- [サンプル README](../README.md) — ホストシミュレーション、Stage 1–5の実行方法、座標規則、設定

現在動く機能と再現手順はサンプル README を正とします。

## 設計資料

- [ロードマップ](roadmap.md) — Stage ごとの完了条件と未着手の調査項目
- [接続復旧とリソース管理の実験計画](reliability-backlog.md) — 次の実験の優先順位と順序
- [起動・復旧test matrix](startup-recovery-matrix.md) — 起動順序、初回handshake failure、接続後障害の判定基準
- [マルチノードホストモデル](next-experiments.md) — N個のremote peer、公平性、障害、リソース上限の条件と結果
- [既知の制約](limitations.md) — application、buffer、recovery、用途の境界
- [設計判断記録](adr/README.md) — 長期的に維持する application 設計の判断

## 検証記録

- [作業記録](worklog/README.md) — ホストテスト、実機試験、障害調査の時系列記録
- [初回接続timeout後のbounded recovery](worklog/2026-10-24-initial-connection-recovery.md) — 同一boot内復旧の実機結果
- [Controller global queue budget](worklog/2026-10-24-global-queue-budget.md) — 共有上限のhost testと3台実測

## 更新方針

- 本文は日本語を基本とし、API 名、protocol 名、正式な技術用語は必要以上に翻訳しません。
- 現在の使い方を worklog に複製せず、サンプル README へ集約します。
- 実測値には日付、環境、条件、再現 command を添え、確認済みの範囲と一般的な保証を区別します。
- 長期的な判断を変更する場合は、既存 ADR を書き換えず、新しい ADR で置き換えます。
- Stage を完了したら roadmap と worklog を同時に更新します。
