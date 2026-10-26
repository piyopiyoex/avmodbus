# 長時間通信断後の復旧調査

状態: 完了（2026-10-26）

Stage 7では、3台構成のSensors branchを長時間切断した後にdistributionが復旧せず、Sensorsのfree heapが低下した条件を
切り分けた。自動retryの回数やtimeoutを先に増やさず、current policyの再現性とresourceを消費した処理範囲を確認した。

Stage 6の実測結果は[接続復旧とリソース管理の実験結果](reliability-backlog.md)、約199秒の観測区間を含むfailure記録は
[idle 180秒切断worklog](worklog/2026-10-25-idle-180-second-disconnect.md)を正とします。

## 現在分かっていること

- 90秒のremote health timeoutより短い切断では、restartせず同じdistribution connectionへ復帰できる場合があります。
- clean boot後の約90秒切断ではSensorsだけをrestartし、Drive connectionを維持したまま後続trafficへ復帰できました。
- 約180秒を狙った試験では、利用者の操作応答から新しいFC-100 session検出まで約199秒でした。これは厳密な電気的切断時間では
  ありません。
- その試験ではbranch切断中に`net_kernel` restartが完了し、新connectionのreadiness待機がtimeoutしてrestart budgetを
  使い切りました。
- branch復元後、Modbus pollingは約10分間復帰しましたが、distributionは再接続しませんでした。
- Sensorsの`minimum_free_heap_bytes`は14,428 bytes、periodic sampleで直接観測したfree heapの最小値は23,552 bytesでした。
- bounded FC-100 queueの増加は記録されておらず、free heap低下の所有processやruntime内部の原因は未確定です。

`restart_succeeded`はremoteの`net_kernel`停止・再起動処理が成功したことを表し、distribution handshake、Controllerからの
readiness ACK、application probeの成功までは表しません。

## 調査する仮説

次の項目は結論ではなく、比較対象とする仮説です。

1. physical carrierが切断中のままrestartを開始すると、新しいhandshakeが失敗してboot単位のrestart budgetを消費する。
2. half-open connectionまたは失敗したdistribution setupのresourceが解放されず、再試行中のfree heap低下に寄与する。
3. bounded FC-100 queue以外のprocess、mailbox、timer、distribution framingがresourceを保持する。
4. Modbus pollingの復帰だけでは、remoteから新しいdistribution handshakeを安全に開始できる状態を判定できない。

## Lifecycle event

Stage 7ではrestartを次の境界へ分けて記録します。eventには取得可能な場合だけ`free_heap_bytes`、
`largest_free_block_bytes`、`minimum_free_heap_bytes`を付けます。

| event | 意味 |
| --- | --- |
| `restart_started` | recovery policyがrestartを選択した |
| `kernel_stop_requested` | `net_kernel.stop/0`を呼び出す直前 |
| `kernel_stop_completed` | `:net_kernel`の登録解除を確認した |
| `kernel_stop_failed` | stop呼び出しまたは登録解除待機が失敗した |
| `kernel_start_started` | 新しい`net_kernel.start/2`を呼び出す直前 |
| `kernel_start_succeeded` | `net_kernel.start/2`が成功した |
| `kernel_start_failed` | `net_kernel.start/2`が失敗した |
| `restart_succeeded` | 新しいconnection IDとhealth stateを作成した |
| `readiness_wait_started` | Controllerへのannounceとreadiness待機を開始した |
| `readiness_acknowledged` | 新しいconnection IDに対するController ACKを受信した |
| `restart_deferred` | ACK timeoutを検出したが、transport復帰確認までbudget消費を保留した |
| `transport_resumed` | 長時間gap後の最初の有効なFC-100 exchangeを受理した |
| `transport_ready` | 設定回数の有効なFC-100 exchangeを連続して受理した |
| `remote_reconnected` | Controllerが新しいremote identityを採用した |
| `recovery_verified` | 対象remoteと正常peerのapplication probeが成功した |

`kernel_start_succeeded`より後のeventがなければ、kernel restartだけをdistribution recovery成功として扱いません。

## 実験順序

### Phase 1: 観測基盤

- [x] kernel stop / startとdistribution reconnectionを別eventにする
- [x] restart境界へmemory snapshotを付ける
- [x] host reportで新しいevent件数を集計する
- [x] 3 roleのAtomVM compatibility checkとPackBEAM buildを通す
- [x] instrumented firmwareを3台へ導入する

process数やmailbox量はAtomVM v0.7 snapshotで利用できるAPIを確認してから追加します。取得できない値を完了条件にはしません。
host testとbuild結果は[Stage 7計測基盤worklog](worklog/2026-10-25-stage-7-recovery-instrumentation.md)に記録した。

### Phase 2: 現行ポリシーの基準値

各scenarioは3台のclean bootから開始し、同じbootでrestart budgetを持ち越しません。

- [x] 障害なしで接続、periodic metrics、lifecycle eventのbaselineを記録する
- [x] 90秒のhealth timeoutより短いSensors branch切断を行い、同じconnectionへ復帰する経路を記録する
- [x] health timeoutを越えた約97秒の操作応答区間でrestart failureを再現する
- [x] Stage 6の約199秒とStage 7の約97秒のcurrent policy failureを比較し、追加の180秒再現を不要と判断する
- [x] Drive connection、Unit 1 polling、queueを最後まで記録する

branch取り外しと復元は外部時計でも記録し、serial logから推定した区間と分けます。短時間baselineと長時間failureを同じbootで
連続実行しません。

current policyの比較結果は
[長時間通信断時の現行ポリシー基準値](worklog/2026-10-26-stage-7-current-policy-baseline.md)に記録した。

### Phase 3: Restart timingの比較

Phase 2でfailureを再現できた場合だけ、current policyとtransport復帰後までrestartを保留するpolicyを比較します。
transport readinessは、remote Serverが長時間のexchange gap後に、有効なFC-100 exchangeを既定2回連続して受理した状態と
定義します。単発のpoll成功ではrestartせず、FC-100 responseがControllerへ到達したことまでは保証しません。同じconnectionの
readiness ACKが先に復帰した場合はrestart保留を解除します。

- [x] transport readinessを表す最小stateとeventを設計する
- [x] current policyを変更しないcontrol scenarioを残す
- [x] deferred restartをopt-in設定として実装する
- [x] 長時間切断でrestart attempt、handshake、reconnection、probeを比較する
- [x] budget拒否、正常peerへの影響、復旧時間を記録する

`ROBOT_MULTINODE_DEFER_RESTART_UNTIL_TRANSPORT_READY=false`を既定値としてcurrent policyを維持します。比較時はremote側だけで
この設定を有効にし、`ROBOT_MULTINODE_TRANSPORT_READY_CONFIRMATIONS=2`を使用します。Serverがrequestを受信し続ける非対称な
response blackoutにはexchange gapが生じないため、このpolicyの対象外です。

実機ではcurrent policyが約97秒の操作応答区間でkernel stopに失敗した一方、deferred policyは約350.8秒のFC-100 exchange gap後に
自動復旧した。比較した切断時間は同一ではないが、transport readyより前にkernel stopを行わないという対象条件は確認できた。
詳細は[transport復帰後のrestart保留](worklog/2026-10-26-stage-7-deferred-restart.md)を正とする。

## 完了条件

- clean bootから長時間通信断後のfailureまたは自動復旧を再現できる
- kernel stop / start、handshake、readiness、application probeのどこで停止したか説明できる
- free heap低下が始まるevent区間を絞り込めるか、現在の計測では絞れない理由を記録できる
- current policyとrestart timingを変更したpolicyを同じ判定項目で比較できる
- 復旧可能な条件と既知の制約をworklogと`limitations.md`へ反映できる

2026-10-26の実機比較で上記を達成した。Stage 7では、長時間物理通信断中のrestart timingがkernel stop failureへ影響する範囲を
絞り込めた。AtomVM内部resourceの一般的な所有関係や、すべてのfailure modelの解明までは主張しない。

原因を特定できた場合だけ修正を別taskとして判断します。Stage 7ではAVModbus core、FC-100 wire protocol、専用
`modbus_dist` carrierを変更せず、AtomVM upstreamへのIssue / PRも作成しません。
