# 0026: transport観測をrecovery policyから分離する

## 状態

採用

## 背景

Stage 7の`transport_resumed`と`transport_ready`は、deferred restartを有効にしたremoteだけが出力していた。Current policyでは同じeventを
取得できないため、2つのpolicyを共通の測定項目で比較できない。

Transportの復帰を観測することと、その結果を使ってdistribution restartを開始することは別の責任である。

## 判断

- `ROBOT_MULTINODE_TRANSPORT_ACTIVITY_TRACE`を独立したopt-in設定として追加する。
- この設定は長時間gap後のFC-100 exchangeを観測するが、remote health stateとrestart budgetを変更しない。
- Deferred policyは従来どおりobserverを内部で有効にし、`transport_ready`をrestart判断に利用する。
- Current policyでtraceだけを有効にした場合は、eventを記録した後に既存のhealth loopへ戻る。
- Trace出力を確実に残すため、この設定は`ROBOT_MULTINODE_CONNECTION_TRACE=true`と組み合わせる。

## 影響

- Current / deferred policyを同じtransport eventで比較できる。
- Current policyのrestart timing、timeout、budgetは変わらない。
- Observer messageとmemory snapshotの計測負荷が加わるため、通常構成では無効のままとする。
- Transport eventはdistribution接続済みのloopだけでなく、restart後のreadiness待ちでも記録する。
- Application processがrestart failure後に停止した場合、復線後のobserver eventを処理できない。この欠損自体をfailure結果として扱う。
- AVModbus coreとFC-100 wire protocolは変更しない。
