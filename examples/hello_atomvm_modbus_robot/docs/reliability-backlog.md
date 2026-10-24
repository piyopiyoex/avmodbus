# 接続復旧とリソース管理の実験計画

3台構成をphysical integration baselineとして維持し、ノード数を増やす前に、現在保証できない接続復旧と
リソース管理を調べます。既存の同時通信、物理RS485切断、reboot recovery、32 remote peer host modelを
単に反復するのではなく、未検証の境界へ対象を絞ります。

## 優先順位

| 優先度 | タスク | 主な検証環境 |
| --- | --- | --- |
| P0 | 接続の初期化・再接続を安定させる | host + 3台 |
| P0 | 複数peerのglobal memory budgetを設計する | host → 3台 |
| P1 | 長時間通信断からの復旧を反復検証する | 3台 |
| P1 | 数時間の連続運転とmemory推移を測定する | 3台 |
| P2 | 3本目のdistribution connectionを実機検証する | 必要な場合だけ4台 |

## Task 1: 接続の初期化・再接続

最初に[起動・復旧test matrix](startup-recovery-matrix.md)を作り、既存の接続管理を変更する前のbaselineを残します。

- Controller / Drive / Sensorsの起動順序をmatrix化する
- 初回handshake failureと接続確立後の通信断を分離する
- stale connectionの検出、remote-side restart、再接続を同じevent形式で記録する
- 一方のconnectionを復旧するときに、もう一方のpeer identityと疎通を維持できるか確認する
- 自動復旧または具体的なruntime blockerのどちらかをscenarioごとに記録する

AtomVM固定の7秒setup timerは、原因を切り分ける前に変更しません。

2026-10-24に6起動順序とDrive / Sensorsの初回failureを実機で固定し、初回timeout後の
bounded remote restartで両roleの同一boot内復旧を確認しました。baselineは
[起動・復旧worklog](worklog/2026-10-24-startup-recovery-matrix.md)、修正後は
[初回接続復旧worklog](worklog/2026-10-24-initial-connection-recovery.md)を参照してください。

## Task 2: Global memory budget

streamごとの8 KiB / 256 chunks上限とは別に、Controller全体の上限を設計します。

- 全peerのqueue使用量を集計する
- global byte / chunk budgetと拒否理由を定義する
- ACK、session reset、adapter終了時のbudget解放をhost testで確認する
- Controllerとremoteのfree heapを実機で測定する

queue上限はAtomVM process、mailbox、distribution framingを含むVM全体の上限ではないため、別々に記録します。

## Task 3: 長時間通信断からの復旧

Task 1完了後、30秒、90秒、180秒の通信断と同一peerの反復切断を試します。正常peerの継続、restart budget、
欠損・重複、application retryをscenarioごとに記録します。正常な256+256通信でもreadiness ACK間隔が約24秒まで
伸びた実測値があるため、短いtimeoutを根拠なく採用しません。

## Task 4: 長時間安定性

Task 2の計測基盤を再利用し、まず1時間の連続通信を対象にします。3 roleのmemory、queue high-water、transaction
timeout、再接続回数を時系列で記録し、idleとactive trafficを交互に実行します。

## Task 5: 限定的な4台目の検証

[ADR 0020](adr/0020-model-scale-on-host-instead-of-adding-devices.md)に従い、4台目は通常の完了条件にしません。
3本目のgenuine distribution handshake、AtomVM実memory、UART / RS485 timingというhost modelでは答えられない
具体的な仮説が生じた場合だけ、`power@modbus.local`（Unit ID 3）を追加します。

## PRの順序

1. [x] Startup / recovery test matrix
2. [x] matrixで再現したstartup / stale connectionの最小修正
3. [ ] Global resource budget
4. [ ] Extended fault / endurance tests

当面、AVModbus core、FC-100 wire protocol、仮想ロボット機能、専用`modbus_dist` carrierは変更しません。
AtomVMのlocal compatibility patchは検証済みbaselineとして扱い、新しいruntime変更が必要と確認できた場合に
このrepositoryの文書とlocal patchで整理します。
