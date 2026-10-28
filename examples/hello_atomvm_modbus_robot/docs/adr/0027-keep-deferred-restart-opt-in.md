# 0027: Deferred restartをopt-inのまま維持する

## 状態

採用

## 背景

Stage 8ではSensors branchを長時間切断し、current policyとdeferred policyを各4回比較した。Currentは0 / 4、deferredは4 / 4で、
deferredはtransport復帰から10.690–12.119秒でapplication probeまで回復した。

一方、deferred policyの復帰signalはremote側で有効なFC-100 exchangeが長時間途切れたことを前提とする。Serverがrequestを
受信し続け、responseだけがControllerへ届かない非対称障害では、この条件を満たさない。

## 判断

- `ROBOT_MULTINODE_DEFER_RESTART_UNTIL_TRANSPORT_READY`の既定値は`false`を維持する。
- 1 connectionだけを持つremoteの物理branch切断を調べるopt-in実験機能として提供する。
- Remote health timeoutとrestart上限は変更しない。
- Stage 9で非対称response blackoutを再現し、双方向の成立を示す追加signalが必要か判断する。

## 影響

- 既存profileのrestart timingは変わらない。
- 物理branch切断の試験では、明示的にdeferred policyを有効化できる。
- Stage 8の4 / 4成功を一般的な復旧保証とは扱わない。
- AVModbus coreとFC-100 wire protocolは変更しない。
