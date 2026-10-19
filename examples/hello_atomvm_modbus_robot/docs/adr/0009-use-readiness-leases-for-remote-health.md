# 0009: remote health は readiness lease で判定する

- Status: accepted
- Date: 2026-10-19

## 背景

Controller が Drive / Sensors の消失を reboot 後の新しい readiness message だけでなく、能動的に検出する必要がある。Erlang の
distributed process monitor を使う設計を最初に実装したが、AtomVM v0.7.0-beta.0 の ESP32-C5 同士を experimental serial carrier
で接続した構成では、remote PID に対する `erlang:monitor(process, Pid)` が `badarg` となり Controller application が終了した。

AtomVM の distributed Erlang documentation は process monitoring を distribution feature に挙げているため、これは一般的に
monitor 非対応と判断する根拠ではない。今回の AtomVM-to-AtomVM、external PID、alternative carrier の組み合わせで再現した
compatibility blocker として扱う。

## 判断

- 現在の example では remote PID に `Process.monitor/1` を使用しない
- 既存 readiness heartbeat の受信時刻を role ごとに保存する
- heartbeat が lease deadline を超えた role を unavailable とし、もう一方の role は維持する
- 新 boot session または同じ process からの heartbeat を受けたら lease を更新する
- unavailable role が readiness を再送したら、再接続 role と継続 peer の両方へ application probe を送る
- default は heartbeat 30秒、health check 5秒、lease 75秒とし、lease は heartbeat 間隔より長くする

## 影響

- AtomVM runtime または distribution carrier を変更せずに remote disappearance を検出できる。
- Drive / Sensors の lease と recovery を独立に扱える。
- failure detection は application message の delivery latency に依存し、native process monitor より遅い。
- lease が短すぎると、正常な heartbeat が Modbus queue 内にある間に false positive が発生する。実機では heartbeat 2秒、lease 5秒で
  両 role の誤 expiry を確認した。
- lease expiry は mission 完了後の Controller loop で処理する。mission 実行中の interruption と reconciliation はまだ扱わない。
- native distributed monitor の failure は AtomVM 側で再現条件を整理して報告する候補とする。
