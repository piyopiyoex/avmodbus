# 作業記録

実機試験、障害調査、測定結果など、再現可能な時系列の記録を置きます。
現在の利用方法は [サンプル README](../../README.md)、長期的な設計判断は
[ADR](../adr/README.md) を正とします。

## 記録

- [2026-10-16: キューメモリーとACK消失](2026-10-16-queue-memory-and-ack-loss.md)
- [2026-10-16: 初回handshakeの進行性と起動順序対策](2026-10-16-initial-handshake-liveness.md)
- [2026-10-16: AtomVM setup PID cleanupとhandshake retryの実機A/B試験](2026-10-16-atomvm-setup-retry.md)
- [2026-10-16: FC-100 peer readiness gateの実機検証](2026-10-16-peer-readiness-gate.md)
- [2026-10-16: Server先行時のidle sync集約の実機検証](2026-10-16-server-idle-sync-coalescing.md)
- [2026-10-16: 外部レビュー追試 — 上限付きキューとRTU frame size](2026-10-16-review-follow-up.md)
- [2026-10-16: 4 KiB転送中のServer再起動復旧](2026-10-16-active-transfer-recovery.md)
- [2026-10-16: 115,200 baudでの512-byte連続試験と4 KiB通信](2026-10-16-high-baud-payloads.md)
- [2026-10-16: Baud rateとpoll intervalの組み合わせ試験](2026-10-16-baud-poll-matrix.md)
- [2026-10-16: 同時起動からの復旧](2026-10-16-simultaneous-startup-recovery.md)
- [2026-10-16: アプリケーション通信の連続試験](2026-10-16-application-traffic-soak.md)
- [2026-10-16: 双方向multi-chunk往復](2026-10-16-bidirectional-multichunk.md)
- [2026-10-16: RTU障害注入](2026-10-16-rtu-fault-injection.md)
- [2026-10-16: PackBEAM `phash2/2` warning の除去](2026-10-16-packbeam-phash2.md)
- [2026-10-16: Modbusトランザクションのトレース](2026-10-16-transaction-tracing.md)
- [2026-10-16: 大容量のgenuine distribution payload](2026-10-16-large-distribution-payload.md)
- [2026-10-16: 64 KiB byte stream負荷試験](2026-10-16-byte-stream-stress.md)
- [2026-10-16: sequence wraparound検証](2026-10-16-sequence-wraparound.md)
- [2026-10-16: sessionを考慮した再起動復旧](2026-10-16-session-recovery.md)
- [2026-10-15: XIAO ESP32-C5 2台での実機検証](2026-10-15-hardware-verification.md)
