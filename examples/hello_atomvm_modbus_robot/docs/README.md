# ドキュメント

この実験のドキュメントは、現在の利用方法、計画、設計判断、検証記録に分けています。

## 利用方法

- [サンプル README](../README.md) — ホストシミュレーション、Stage 1–7の実行方法、座標規則、設定

現在動く機能と再現手順はサンプル README を正とします。

## 設計資料

- [ロードマップ](roadmap.md) — Stage ごとの完了条件、実証済み範囲、対象外の項目
- [接続復旧とリソース管理の実験結果](reliability-backlog.md) — Stage 6の実施順序、結果、任意の追加検証
- [長時間通信断後の復旧調査](long-outage-recovery-plan.md) — Stage 7の仮説、lifecycle event、比較手順
- [起動・復旧test matrix](startup-recovery-matrix.md) — 起動順序、初回handshake failure、接続後障害の判定基準
- [長時間通信断・安定性test plan](endurance-test-plan.md) — 30 / 90 / 180秒切断と約1時間運転の条件・判定方法
- [マルチノードホストモデル](next-experiments.md) — N個のremote peer、公平性、障害、リソース上限の条件と結果
- [既知の制約](limitations.md) — application、buffer、recovery、用途の境界
- [設計判断記録](adr/README.md) — 長期的に維持する application 設計の判断

## 検証記録

- [作業記録](worklog/README.md) — ホストテスト、実機試験、障害調査の時系列記録
- [初回接続timeout後のbounded recovery](worklog/2026-10-24-initial-connection-recovery.md) — 同一boot内復旧の実機結果
- [Controller global queue budget](worklog/2026-10-24-global-queue-budget.md) — 共有上限のhost testと3台実測
- [長時間試験の計測基盤](worklog/2026-10-24-endurance-instrumentation.md) — 反復run、定期metrics、host log集計
- [短時間切断と長時間復旧](worklog/2026-10-24-extended-fault-recovery.md) — Sensors branch切断中のDrive継続、restart失敗と成功の境界
- [idle 180秒切断](worklog/2026-10-25-idle-180-second-disconnect.md) — physical復帰後のdistribution再接続失敗とresource枯渇
- [同一boot反復切断](worklog/2026-10-25-repeated-branch-disconnect.md) — 短時間切断3回のconnection維持と完全配送
- [約1時間のactive / idle耐久試験](worklog/2026-10-25-one-hour-active-idle-endurance.md) — 12 runsの完全配送、memory推移、散発timeout
- [Stage 7 長時間通信断時の現行ポリシー基準値](worklog/2026-10-26-stage-7-current-policy-baseline.md) — timeout未満の同一connection復帰とkernel stop failure
- [Stage 7 transport復帰後のrestart保留](worklog/2026-10-26-stage-7-deferred-restart.md) — transport復帰確認後にbudgetを消費するopt-in policy

## 更新方針

- 本文は日本語を基本とし、API 名、protocol 名、正式な技術用語は必要以上に翻訳しません。
- 現在の使い方を worklog に複製せず、サンプル README へ集約します。
- 実測値には日付、環境、条件、再現 command を添え、確認済みの範囲と一般的な保証を区別します。
- 長期的な判断を変更する場合は、既存 ADR を書き換えず、新しい ADR で置き換えます。
- Stage を完了したら roadmap と worklog を同時に更新します。
