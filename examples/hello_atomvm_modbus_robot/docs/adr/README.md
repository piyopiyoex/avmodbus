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
- [0006: boot session ID で remote node の再起動を識別する](0006-identify-remote-boots-with-session-ids.md)
- [0007: Server 間の application message は Controller で中継する](0007-relay-server-application-messages-through-controller.md)
- [0008: sensor に基づく navigation 判断は Controller で行う](0008-make-navigation-decisions-in-controller.md)
- [0009: remote health は readiness lease で判定する](0009-use-readiness-leases-for-remote-health.md)
- [0010: concurrent producer を application ACK で制限する](0010-bound-concurrent-producers-with-application-acks.md)
- [0011: ACK timeout 時は remote 側 distribution を再起動する](0011-restart-remote-distribution-after-ack-timeout.md)
- [0012: readiness ACK で remote distribution health を判定する](0012-detect-remote-health-with-readiness-acks.md)
- [0013: shared Client の poll を round-robin で直列化する](0013-schedule-shared-client-polls-round-robin.md)
- [0014: mission は Controller の health loop 外で実行する](0014-run-missions-outside-the-health-loop.md)
- [0015: mission commandをDrive bootへ束縛する](0015-bind-mission-commands-to-drive-boots.md)
- [0016: indeterminate mission後もhealth loopを継続する](0016-continue-health-after-indeterminate-missions.md)
- [0017: response faultはboard bootごとにone-shotとする](0017-make-response-faults-one-shot-per-boot.md)
- [0018: traffic startをACK付きで再送しrun IDで重複排除する](0018-retry-traffic-starts-with-idempotent-run-ids.md)
