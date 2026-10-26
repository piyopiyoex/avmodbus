# ドキュメント

この実験のドキュメントは、現在の利用方法、計画、設計判断、検証記録に分けています。

## 利用方法

- [サンプル README](../README.md) — ホストシミュレーション、Stage 1–8の実行方法、座標規則、設定

現在動く機能と再現手順はサンプル README を正とします。

## 設計資料

- [ロードマップ](roadmap.md) — Stage ごとの完了条件、実証済み範囲、対象外の項目
- [接続復旧とリソース管理の実験結果](reliability-backlog.md) — Stage 6の実施順序、結果、任意の追加検証
- [長時間通信断後の復旧調査](long-outage-recovery-plan.md) — Stage 7の仮説、lifecycle event、比較手順
- [Stage 8–12 次期復旧実験](recovery-experiments.md) — recovery再現性、非対称障害、runtime、application recoveryの計画
- [Stage 8 recovery policy反復試験](stage-8-recovery-repeatability.md) — 120秒・300秒切断のmatrix、結果、採用判断
- [起動・復旧test matrix](startup-recovery-matrix.md) — 起動順序、初回handshake failure、接続後障害の判定基準
- [長時間通信断・安定性test plan](endurance-test-plan.md) — 30 / 90 / 180秒切断と約1時間運転の条件・判定方法
- [マルチノードホストモデル](next-experiments.md) — N個のremote peer、公平性、障害、リソース上限の条件と結果
- [既知の制約](limitations.md) — application、buffer、recovery、用途の境界
- [設計判断記録](adr/README.md) — 長期的に維持する application 設計の判断

## 検証記録

- [作業記録](worklog/README.md) — ホストテスト、実機試験、障害調査の時系列索引

個別の測定値は作業記録だけに置き、ロードマップと設計資料から該当記録へリンクします。

## 更新方針

- 本文は日本語を基本とし、API 名、protocol 名、正式な技術用語は必要以上に翻訳しません。
- 現在の使い方を worklog に複製せず、サンプル README へ集約します。
- 実測値には日付、環境、条件、再現 command を添え、確認済みの範囲と一般的な保証を区別します。
- 長期的な判断を変更する場合は、既存 ADR を書き換えず、新しい ADR で置き換えます。
- Stage を完了したら roadmap と worklog を同時に更新します。
