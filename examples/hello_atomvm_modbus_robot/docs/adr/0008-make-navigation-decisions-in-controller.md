# 0008: センサーに基づくナビゲーション判断はControllerで行う

- Status: accepted
- Date: 2026-10-19

## 背景

Stage 3 では Sensors の sample を Controller 経由で Drive へ届けられることを確認した。次に、通信確認だけでなく distributed
application として sample に応じて movement command を変える必要がある。判断を Sensors、Drive、Controller のどこに置くか、また
lost reply や Controller reboot に対して command ID をどう扱うかを決める必要がある。

## 判断

- Sensors は deterministic な観測値だけを生成し、navigation policy を持たない
- `RobotSim.Navigator` を pure function とし、Controller 上で sample から reason と command を決める
- battery が 20% 以下なら `:status` で位置を保持する
- battery が十分で distance が 400 mm 以下なら右へ 90° 旋回する
- それ以外は 100 mm 前進する
- 各 step を `sample relay -> decision -> Drive command/reply` の順で直列実行する
- timeout retry は同じ request ID を使い、Controller の新しい起動では random boot-scoped ID から新しい range を開始する

## 影響

- sensor model、navigation policy、Drive state transition を独立して host test できる。
- fresh Sensors の先頭 3 sample は `500, 450, 400 mm` であり、command は `forward, forward, right turn`、最終 state は
  `(200, 0, 90°)` になる。
- low-battery branch は host test 済みだが、現在の短い実機 mission では battery が 20% に達しない。
- step は直列であり、1 step に複数の distribution round trip が必要になるため latency は大きい。
- request ID は衝突確率を持つ volatile な値であり、durable mission identity ではない。
- Controller または remote の reboot 中に mission を継続・再構築する reconciliation は別途必要である。
