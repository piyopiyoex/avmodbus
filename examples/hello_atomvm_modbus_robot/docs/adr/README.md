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

- [0001: +Xから時計回りに増える方位角を使う](0001-use-clockwise-heading-from-positive-x.md)
- [0002: request IDでコマンド再試行を重複排除する](0002-deduplicate-retries-with-request-ids.md)
- [0003: 既存exampleの実験用キャリアを再利用する](0003-reuse-the-existing-experimental-carrier.md)
- [0004: 3ノード分散接続より先に標準マルチドロップを検証する](0004-validate-standard-multidrop-before-distribution.md)
- [0005: 1個のModbus Clientを複数の分散接続ストリームで共有する](0005-share-one-client-across-distribution-streams.md)
- [0006: 起動session IDでリモートノードの再起動を識別する](0006-identify-remote-boots-with-session-ids.md)
- [0007: Server間のアプリケーションメッセージはControllerで中継する](0007-relay-server-application-messages-through-controller.md)
- [0008: センサーに基づくナビゲーション判断はControllerで行う](0008-make-navigation-decisions-in-controller.md)
- [0009: リモート健全性はreadiness leaseで判定する](0009-use-readiness-leases-for-remote-health.md)
- [0010: 同時プロデューサーをapplication ACKで制限する](0010-bound-concurrent-producers-with-application-acks.md)
- [0011: ACK timeout時はリモート分散接続を再起動する](0011-restart-remote-distribution-after-ack-timeout.md)
- [0012: readiness ACKでリモート分散接続の健全性を判定する](0012-detect-remote-health-with-readiness-acks.md)
- [0013: 共有Clientのpollをラウンドロビンで直列化する](0013-schedule-shared-client-polls-round-robin.md)
- [0014: ミッションはControllerのヘルスチェックループ外で実行する](0014-run-missions-outside-the-health-loop.md)
- [0015: ミッションコマンドをDrive起動へ束縛する](0015-bind-mission-commands-to-drive-boots.md)
- [0016: 結果不明のミッション後もヘルスチェックループを継続する](0016-continue-health-after-indeterminate-missions.md)
- [0017: 応答障害はボード起動ごとに1回だけ有効にする](0017-make-response-faults-one-shot-per-boot.md)
- [0018: 通信開始をACK付きで再送しrun IDで重複排除する](0018-retry-traffic-starts-with-idempotent-run-ids.md)
- [0019: Controllerのトランスポート構成をpeer descriptorリスト駆動にする](0019-drive-controller-transport-from-peer-descriptors.md)
- [0020: 実機を1台ずつ増やさずホストモデルで規模を検証する](0020-model-scale-on-host-instead-of-adding-devices.md)
