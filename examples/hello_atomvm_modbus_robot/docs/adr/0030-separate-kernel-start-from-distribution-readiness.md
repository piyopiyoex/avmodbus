# 0030: kernel startとdistribution readinessを別の成功条件にする

## 状態

採用

## 背景

Stage 10のhealthy probeでは、`net_kernel.start/2`成功後にreadiness ACK、Controller再接続、application probeまで完了した。
一方、Sensors branch切断中のprobeでは`net_kernel.start/2`が成功を返した後、distribution setupがtimer timeoutで終了した。
Branch復帰後はFC-100 transactionだけが再開し、distributionは自動再接続しなかった。

## 判断

- `kernel_start_succeeded`は`net_kernel.start/2`の返却成功だけを表す。
- `restart_succeeded`はlocal lifecycleのstop / start完了だけを表し、connection復旧の成功条件にしない。
- Remoteのreadiness ACK、Controllerの`remote_reconnected`、application probeを別々に記録する。
- Connection復旧は対象scenarioに必要な境界がすべて成功した場合だけ完了とする。
- Setup timeout後のretryやadapter cleanupは、原因を特定するまで自動化しない。

## 影響

- Lifecycle logだけで復旧成功率を過大評価しない。
- Physical FC-100 pollingの復帰とdistribution handshakeの復帰を区別する。
- AtomVM runtimeの変更やupstreamへのIssue / PRは、この判断の対象外とする。
- 実測値は [検証結果](../worklog/README.md) を正とする。
