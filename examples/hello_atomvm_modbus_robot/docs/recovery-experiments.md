# Stage 8–12 次期復旧実験

Stage 9までの結果を基準に、3台構成でruntime lifecycleとapplication recoveryを調べる。
4台目は具体的な実機仮説が生じた場合だけ使用する。

## Stage 8: Recovery policyの再現性

状態: 完了

- [x] recovery-only試験とtraffic試験の成功判定をreport上で分離する
- [x] transport readyからapplication probe成功までのhost timestamp差を集計する
- [x] current / deferred policyの共通測定項目を固定する
- [x] 約120秒・300秒の通信断をclean bootから反復する
- [x] 成功率、復旧時間、restart budget、free heap、Drive connectionを比較する
- [x] deferred policyを既定値にするか、opt-inを維持するか判断する

各runは独立したtime windowとして集計し、単発の成功を一般的な復旧保証とは扱わない。
条件と操作手順は[Stage 8 recovery policy反復試験](stage-8-recovery-repeatability.md)を正とする。
Currentは0 / 4、deferredは4 / 4だった。Stage 8時点では非対称response blackoutが未検証だったため、deferredは既定値へ変更せず
opt-inを維持した。
実測値は[作業記録](worklog/2026-10-26-stage-8-recovery-repeatability.md)を参照する。

## Stage 9: 非対称通信障害

状態: 完了

- [x] Example内に限定したFC-100 response blackoutを設計する
- [x] Request受信とresponse outcomeを別eventとして記録する
- [x] current / deferred policyと正常なDrive connectionへの影響を比較する
- [x] 双方向の通信成立を示す追加signalが必要か判断する

Currentは2 / 2でrestart後に復旧し、deferredは2 / 2でrestartを保留したまま180秒以内に復旧しなかった。4 runsすべてでDriveを
維持した。Request受理だけではresponse経路の復帰を判定できないため、将来の改善にはController側のresponse受信を確認できる
双方向signalが必要である。Stage 9ではsignalを追加せず、deferredをopt-inのまま維持する。条件と結果は
[Stage 9試験](stage-9-asymmetric-response-blackout.md)と[実機比較](worklog/2026-10-27-stage-9-asymmetric-response-blackout.md)を参照する。

## Stage 10: AtomVM distribution lifecycle

- [ ] `net_kernel` stop / startの最小再現をexample内に作る
- [ ] Setup failureとstop failureを別scenarioとして扱う
- [ ] 利用可能なAPIでprocess、mailbox、heapの前後差を測定する
- [ ] Runtime内部とexample側lifecycle管理の責任範囲を切り分ける

AtomVM upstreamへのIssue / PRは作成せず、対象v0.7 snapshotの結果と必要なlocal patchをrepository内に記録する。

## Stage 11: Application recovery

- [ ] Mission中にSensors branchを切断し、復旧後にsensor dataを再取得する
- [ ] Driveへの未確定commandと重複実行防止を再検証する
- [ ] 正常継続、明示的中断、未確定状態を区別する
- [ ] 復旧後の小規模traffic、queue、memory、application stateを確認する

Durable stateと自動mission resumeは、必要性が確認されるまで実装しない。

## Stage 12: 実機スケール（任意）

Stage 8–11からhost modelでは答えられない仮説が生じた場合だけ、`power@modbus.local`（Unit ID 3）を追加する。3本目の
distribution connection、startup timing、resource、polling fairness、failure isolationを測定する。ノード数を増やすこと自体は
目的にしない。

## 維持する境界

- AVModbus coreとFC-100 wire protocolを変更しない
- transport観測とrecovery policy判断を分離する
- host test、host model、実機結果を区別する
- 実測結果はworklog、設計判断はADR、既知の制約は`limitations.md`へ記録する
