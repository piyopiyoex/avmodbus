# 接続復旧とリソース管理の実験結果

3台構成をphysical integration baselineとして維持し、ノード数を増やす前に接続復旧とリソース管理を調べました。
2026-10-25までにP0 / P1を完了し、4台目は具体的な仮説が生じた場合だけ行う任意の検証として残しています。
既存の同時通信、物理RS485切断、reboot recovery、32 remote peer host modelの単純な反復ではなく、
それまで保証できなかった境界を対象にしました。

## 優先順位

| 優先度 | タスク | 状態 | 主な検証環境 |
| --- | --- | --- | --- |
| P0 | 接続の初期化・再接続を安定させる | 完了 | host + 3台 |
| P0 | 複数peerのglobal memory budgetを設計する | 完了 | host → 3台 |
| P1 | 長時間通信断からの復旧を反復検証する | 完了 | 3台 |
| P1 | 約1時間の連続運転とmemory推移を測定する | 完了 | 3台 |
| P2 | 3本目のdistribution connectionを実機検証する | 条件付き保留 | 必要な場合だけ4台 |

## Task 1: 接続の初期化・再接続

最初に[起動・復旧test matrix](startup-recovery-matrix.md)を作り、既存の接続管理を変更する前のbaselineを残しました。

- [x] Controller / Drive / Sensorsの起動順序をmatrix化する
- [x] 初回handshake failureと接続確立後の通信断を分離する
- [x] stale connectionの検出、remote-side restart、再接続を同じevent形式で記録する
- [x] 一方のconnectionを復旧するときに、もう一方のpeer identityと疎通を維持できるか確認する
- [x] 自動復旧または具体的なruntime blockerのどちらかをscenarioごとに記録する

AtomVM固定の7秒setup timerは、原因を切り分ける前に変更しません。

2026-10-24に6起動順序とDrive / Sensorsの初回failureを実機で固定し、初回timeout後の
bounded remote restartで両roleの同一boot内復旧を確認しました。baselineは
[起動・復旧worklog](worklog/2026-10-24-startup-recovery-matrix.md)、修正後は
[初回接続復旧worklog](worklog/2026-10-24-initial-connection-recovery.md)を参照してください。

## Task 2: Global memory budget

streamごとの8 KiB / 256 chunks上限とは別に、Controller全体の上限を設計します。

- [x] 全peerのqueue使用量を集計する
- [x] global byte / chunk budgetと拒否理由を定義する
- [x] 複数peerが同時に上限へ達するhost testを追加する
- [x] ACK、session reset、adapter終了時のbudget解放をhost testで確認する
- [x] Controllerとremoteのfree heapを実機で測定する

queue上限はAtomVM process、mailbox、distribution framingを含むVM全体の上限ではないため、別々に記録します。
設計とhost結果は[ADR 0023](adr/0023-bound-controller-queues-with-a-global-budget.md)と
[global queue budget worklog](worklog/2026-10-24-global-queue-budget.md)を参照してください。

## Task 3: 長時間通信断からの復旧

Task 1完了後、30秒、90秒、180秒の通信断と同一peerの反復切断を試し、正常peerの継続、restart budget、
欠損・重複、application retryをscenarioごとに記録しました。正常な256+256通信でもreadiness ACK間隔が約24秒まで
伸びた実測値があるため、短いtimeoutは採用していません。

- [x] 単発切断と反復切断のscenario、判定基準を固定する
- [x] connection eventとtraffic結果をhostで集計する
- [x] 約30秒の単発切断を3台で実行する
- [x] 約90秒のidle接続中の単発切断を3台で実行する
- [x] 約90秒の通信中切断を3台で実行する
- [x] 約180秒のidle接続中の単発切断を3台で実行する
- [x] 同一peerの切断・復帰を同一bootで反復する

約30秒runではDrive / Sensors各64 messagesを欠損・重複なしで完了し、restartを行わず同じconnectionへ復帰しました。
事前calibrationの約1分超切断ではControllerの`net_tick_timeout`後にSensorsのremote-side restartが
`net_kernel_stop_timeout`となり、Unit 2も応答不能になるblockerを再現しました。条件と結果は
[worklog](worklog/2026-10-24-extended-fault-recovery.md)を参照してください。
その後の約90秒を狙ったidle接続中の切断では、Sensorsのremote-side restart、再接続、probeに成功し、Drive connectionを
維持しました。電気的切断時間は外部時計で確定していません。
同じSensors bootで長時間切断を反復するとrestart budgetが枯渇し、physical polling復帰後もdistributionは再接続せず、
進行中producerがapplication ACK timeoutで停止することも確認しました。独立scenarioでは各remoteをresetし、budgetを
持ち越さない必要があります。

その後、clean bootで通信中の約90秒切断を実行しました。faultを含むrunはSensors 38 / 64でtimeoutとなりましたが、
Driveは64 / 64を完了してconnectionを維持しました。Sensorsはrestart直後のhandshakeに失敗し、bounded queueの
stream resetを経て約6分後に再接続しました。後続runは両role 64 / 64を欠損・重複なしで完了しています。現在の保証は
「正常peerを維持して後続runへ復旧できた」であり、「進行中runを完全配送できる」ではありません。

約180秒を狙ったidle切断では、復線後にphysical pollingが一度復帰したもののdistributionは再接続しませんでした。
Sensors free heapは約83 KiBからminimum 14,428 bytesまで低下し、約11分後にFC-100 serverも再び応答不能になりました。
Drive connectionは維持しています。これは自動復旧の成功ではなく、正常peerを分離したまま再現できるcurrent v0.7 snapshotの
runtime blockerです。詳細は[180秒切断worklog](worklog/2026-10-25-idle-180-second-disconnect.md)を参照してください。

同一bootでSensors branchの短時間切断を3回反復した試験では、90秒のremote health timeoutへ達せず、同じdistribution
connectionのまま復帰しました。faultを含む2 runsと後続runは両role 64 / 64、欠損・重複なしで完了し、restart budget消費と
global queue rejectionは0でした。操作時間は共通時計で精密測定していないため、観測した連続timeoutとACK gapを
[反復切断worklog](worklog/2026-10-25-repeated-branch-disconnect.md)に分けて記録しています。

## Task 4: 長時間安定性

Task 2の計測基盤を再利用し、約1時間の連続通信を対象にしました。3 roleのmemory、queue high-water、transaction
timeout、再接続回数を時系列で記録し、idleとactive trafficを交互に実行しました。

- [x] boundedなtraffic run反復とrun間idleを実装する
- [x] 3 roleのperiodic resource logとhost reportを追加する
- [x] 約1時間のactive / idle profileを3台で実行する
- [x] memory、queue、timeout、restartの時系列をworklogへ記録する

2026-10-25に64分30秒の12-run profileを実行し、Drive / Sensors各192 messagesを欠損・重複なしで配送しました。
restartとglobal rejectionは0、periodic free heapの単調減少はありませんでした。Sensorsのtransaction timeout 8件は
retryで回復しましたが、error-freeなphysical transportとは扱いません。条件とmemory推移は
[約1時間の耐久試験worklog](worklog/2026-10-25-one-hour-active-idle-endurance.md)を参照してください。

## Task 5: 限定的な4台目の検証

[ADR 0020](adr/0020-model-scale-on-host-instead-of-adding-devices.md)に従い、4台目は通常の完了条件にしません。
3本目のgenuine distribution handshake、AtomVM実memory、UART / RS485 timingというhost modelでは答えられない
具体的な仮説が生じた場合だけ、`power@modbus.local`（Unit ID 3）を追加します。

## 実施順序

1. [x] Startup / recovery test matrix
2. [x] matrixで再現したstartup / stale connectionの最小修正
3. [x] Global resource budget
4. [x] Extended fault / endurance tests

当面、AVModbus core、FC-100 wire protocol、仮想ロボット機能、専用`modbus_dist` carrierは変更しません。
AtomVMのlocal compatibility patchは検証済みbaselineとして扱い、新しいruntime変更が必要と確認できた場合に
このrepositoryの文書とlocal patchで整理します。
