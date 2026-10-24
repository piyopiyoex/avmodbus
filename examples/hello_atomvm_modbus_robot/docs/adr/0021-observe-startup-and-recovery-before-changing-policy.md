# 0021: 復旧policyを変更する前に起動・復旧matrixを固定する

## 状態

採用

## 背景

3台構成では起動順序、AtomVM固定の7秒setup timeout、非対称half-open connection、remote-side restartが相互に影響します。
既存の実機記録は個別failureを説明できますが、初回handshake failureと接続後障害を同じ基準で比較するmatrixがありません。

timeoutやrestart policyを先に変更すると、改善前の再現条件と証跡が失われ、exampleとruntimeの責務を切り分けにくくなります。

## 判断

接続管理の動作を変更する前に、次を固定します。

- 3 roleの全起動順序
- Drive / Sensorsそれぞれの初回handshake failure
- Drive / Sensorsそれぞれの接続後障害
- machine-readableなconnection event
- 復旧対象と正常peerを別々に確認する完了条件

host matrixは実機の代替ではなく、scenario coverageとlog判定の正本として使います。7秒setup timerは原因の切り分け前に
延長しません。

## 影響

- 次の復旧修正はmatrixで再現したfailureに限定できます。
- 自動復旧とruntime blockerを同じworklog形式で比較できます。
- opt-in traceのcodeとtestが増えますが、既定値`false`では通常のconnection lifecycleを変更しません。
- 実機matrixの完了まではstartup / stale recoveryを一般的に保証しません。
