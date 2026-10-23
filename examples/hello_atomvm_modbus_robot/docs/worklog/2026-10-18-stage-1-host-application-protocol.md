# Stage 1 ホストアプリケーションプロトコル — 2026-10-18

## 目的

AtomVM distribution と Modbus carrier を追加する前に、Controller / Drive 間の message、timeout retry、movement の
重複実行防止を host 上で検証する。

## 実装

- `RobotSim.Protocol`: request / reply envelope と type
- `RobotSim.Drive`: rover state の ownership と 32-entry completed-request cache
- `RobotSim.Controller`: sequential command、status verification、timeout retry

Drive は同じ request ID と command を再受信すると cache 済み result を返します。同じ ID の異なる command は
`:request_id_conflict` として拒否します。

## 障害シナリオ

test proxy が最初の request を Drive へ転送し、Drive からの最初の reply だけを破棄しました。Controller は 20 ms の
timeout 後に同じ request ID で retry し、Drive は movement を再実行せず cache 済み result を返しました。

## 結果

```text
14 tests, 0 failures
```

- reference mission を local Controller / Drive process 間で完了した
- 同一 request の再送後も `x_mm = 100` であり、200 mm へ重複移動しなかった
- request ID conflict を拒否し、rover state を変更しなかった
- bounded cache から ID が eviction された後は再実行されることを test で明示した
- reply が得られない場合、設定回数の retry 後に `{:error, :timeout}` を返した
- unsupported GenServer call / cast の failure path は `erlang:phash2/2` に依存しない明示 callback とした

## 残る範囲

この検証は host 上の process messaging に限られます。AtomVM PackBEAM compatibility、remote registered process、
FC-100 carrier、board reboot 後の request history は未検証です。次は carrier の再利用境界を決めてから、2 node 用の
AtomVM application startup を追加します。
