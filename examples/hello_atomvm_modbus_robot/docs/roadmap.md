# ロードマップ

この example は、host-only simulation から 2-node distributed application、3-device Modbus multidrop、
3-node distribution の調査へ段階的に進めます。各 Stage は前段の完了を前提としますが、Stage 3 の成功は
仮定しません。技術的 blocker を特定して記録することも成果とします。

現在の実行方法は [サンプル README](../README.md)、設計判断は [ADR](adr/README.md)、実測結果は
[作業記録](worklog/README.md) を正とします。

## 現在地

| Stage | 状態 | 範囲 |
| --- | --- | --- |
| 0 | 完了 | host-only virtual rover |
| 1 | 完了 | 2-node mission と in-flight Drive reboot の境界を実機確認 |
| 2 | 完了 | 3-device standard Modbus multidrop、120-request soak、独立Server reboot |
| 3 | 基本実証 | 2 remote node の同時接続、Controller relay、複数 tick を実機確認 |
| 4 | 完了 | adaptive mission、readiness lease、reply-loss retry を実機確認 |

## Stage 0: local virtual rover simulation

- [x] 独立した Mix example project を追加する
- [x] position と heading を持つ virtual rover を pure function で実装する
- [x] forward、left / right turn、status command を実装する
- [x] 座標と heading の規則を明示する
- [x] deterministic demonstration mission を追加する
- [x] host-side unit test を追加する
- [x] host 上で format、test、reference mission を実行する
- [x] 日本語の利用手順、ADR、worklog を追加する
- [x] repository CI で example の format と test を実行する

完了条件は、host test が成功し、reference mission が
`{x_mm: 100, y_mm: 50, heading_deg: 90}` で終了することです。

## Stage 1: two-node distributed robot

- [x] 既存 FC-100 / virtual UART carrier の再利用境界を決める
- [x] `controller@modbus.local` と `drive@modbus.local` を構成する
- [x] controller / drive の AtomVM compatibility check と PackBEAM build を通す
- [x] controller を board A、virtual rover process を board B で起動する
- [x] command ID、明示的な reply、timeout を持つ小さな application protocol を定義する
- [x] host 上の drive process で同一 request retry の重複実行を抑止する
- [x] lost reply、timeout、request ID conflict を host test で検証する
- [x] remote registered process へ movement command を送る
- [x] drive node で state transition を実行し、result と status を返す
- [x] reference mission の最終座標を controller code で期待値と比較する
- [x] in-flight command 中の peer reboot を試し、重複実行の扱いを記録する
- [x] 2 台の XIAO ESP32-C5 による実機結果を worklog に記録する

完了条件は、genuine distributed Erlang の message path で 2 台の実機が mission を完了し、controller が
最終 state を検証することです。この基準は 2026-10-18 に達成しました。in-flight command 中の peer reboot は、
transport / distribution は再接続した一方、Drive の volatile state と request cache が失われることを実機で確認しました。
Controller は final state の不一致を mission failure として検出します。永続化または reconciliation による回復は Stage 4
以降の対象としました。2026-10-21のfollow-upではboot guardによるindeterminate outcomeの検出と再実行停止まで追加しました。

## Stage 2: three-device Modbus multidrop

この Stage では Erlang distribution を使わず、standard Modbus RTU の multidrop を先に検証します。

- [x] 3 台目の XIAO ESP32-C5 と HW-519 を shared two-wire bus へ接続する
- [x] drive を Unit ID 1、sensors を Unit ID 2 にする
- [x] controller の single UART から両方の Server を順番に poll する
- [x] transaction が重ならない bus scheduling と UART ownership を確認する
- [x] wiring 条件、fairness、latency、timeout、error behavior を記録する
- [x] 各 Server を独立に reboot して recovery を確認する

完了条件は、1 台の Client が 2 台の Server と同じ RS485 bus 上で安定して standard Modbus 通信できることです。
2026-10-19 に 60 cycle / 120 request を error 0 で完了し、Drive / Sensors の独立 reboot も read retry 内で回復しました。
termination / bias の電気測定と長時間 soak は未実施であり、現在の hardware profile を超える保証には含めません。

## Stage 3: three-node distributed Erlang

- [x] drive と sensors に独立した sequence / ACK / session / byte-stream state を設計する
- [x] 1 本の physical UART を所有する process と polling policy を設計する
- [x] 複数の virtual UART stream を `serial_dist` / `net_kernel` に渡す方法を調査する
- [x] `controller <-> drive` と `controller <-> sensors` の connection を確立する
- [x] 両 remote node の registered process と message を交換する
- [x] Server node 間の message を controller で relay する必要があるか検証する
- [x] 片方の Server reboot 後に再接続し、もう一方の connection が継続することを確認する
- [x] Controller reboot 後に両 Server が再接続して application messaging を再開することを確認する
- [x] 基本疎通に dedicated carrier は不要と判断する
- [ ] AtomVM の multi-connection tick fix を upstream へ提案する
- [x] 継続 application traffic と polling fairness の短時間 baseline を測定する
- [x] application traffic 中に Drive / Sensors を独立 reboot して recovery を確認する
- [x] concurrent producer の短時間 fairness baseline と moderate profile を検証する
- [x] 256+256 messagesの10分間soakでmemory / queue推移を検証する

完了条件は、controller と 2 台の remote node の genuine distribution を実証するか、必要な AtomVM / carrier
変更と blocker を再現可能な形で記録することです。基本疎通、3 role の独立 reboot recovery、60 application round trip の短時間
fairness baseline、traffic 中の両 remote reboot recovery、Sensors から Drive への Controller relay は 2026-10-19 に達成しました。
local AtomVM patch が必要なため Stage 3 は follow-up を残しています。Modbus Server 同士が bus を直接駆動する構成は仮定しません。

## Stage 4: virtual sensors と fault tolerance

- [x] deterministic な virtual distance sample を追加する
- [x] simulated battery sample を追加する
- [x] sensor data に基づいて controller が mission を変更する
- [x] distributed process monitor の blocker を記録し、readiness lease で independent node restart を検証する
- [x] mission 中の application reply loss を3台実機で検証する
- [x] same-ID retry と bounded cache で movement command の重複実行を防ぐ
- [x] bounded queue、recovery behavior、残る制約を[文書化する](limitations.md)

Stage 4 はapplication reply lossまでを2026-10-20に3台の実機で確認して完了とした。その後のfollow-upでphysical RS485 interruptionと、
Drive rebootをまたぐ未確定commandの検出・再実行停止を確認した。durable state、state復元、自動mission resumeは対象外とし、
[既知の制約](limitations.md) に記録している。

## Follow-up: concurrent traffic と信頼性（実機検証中）

- [x] Drive / Sensors の独立 producer と Controller の非同期 collector を opt-in で追加する
- [x] host 側で delivery / duplicate / order / timeout の集計を検証できるようにする
- [x] 3 台の実機で concurrent producer baseline と moderate profile を測定する
- [x] overload profile で Unit別 transaction、queue high-water、heap を測定する
- [x] 64 messages / role の longer run で session reset と application recovery の境界を再現する
- [x] 3台同時consoleでremote outgoing queueの`:queue_full`をsession resetの直接原因として特定する
- [x] application ACK / in-flight window 1で64+64 longer runを完全配送する
- [x] Server response blackout中のACK timeoutとsame-sequence retryを実機で発生させる
- [x] 非対称half-open connectionによりproducer resumeが失敗する境界を記録する
- [x] remote側のstale distribution connectionを明示的にteardownし、再接続後に同じproducerを再開する
- [x] application trafficに依存しないremote healthとdistribution lifecycleを設計する
- [x] connection ID付きreadiness ACK、boot単位のrestart上限、shutdown完了待ちを実機検証する
- [x] remote rebootに対するrecovery、10分間のmemory / queue推移を測定する
- [x] remoteの物理RS485切断・再接続を検証する
- [x] shared Clientのpollをround-robin化し、単一peer切断中も正常peerを維持する
- [x] mission実行をhealth loopから分離し、mission中もreadiness ACK / lease評価を継続する
- [x] reboot時の未確定commandを新bootで再実行せず、indeterminate outcomeとして停止する
- [x] indeterminate mission後もhealth loopを継続し、新Driveのread-only snapshotを記録する
- [x] snapshot確認後のController resetで、現在のDrive stateから新しいguarded missionを開始する
- [ ] AtomVM runtime の upstream follow-up を進める
- [ ] 4 台目の追加は上記の測定結果に基づいて判断する

実行条件、停止条件、測定限界は[次の実験計画](next-experiments.md)に記録します。
2026-10-21のpaired-wire試験ではSensorsまたは右端Driveの切断がbus全体へ影響しました。その後、breadboard上のcontinuous trunkと
node別branchへ変更しました。反復試験でshared Clientのdeadline starvationを発見したためpollをround-robin化し、Sensors branch切断中も
Unit 1 transaction failure 0でDrive connectionを維持することを2 runで確認しました。未使用restart budgetのrunではbranch復帰後に
Controller / SensorsをresetせずSensorsが再接続し、両peerのprobeを完了しました。これで独立branchによる単一peer faultとschedulerの
follow-upは完了です。timeout margin、長時間反復、termination / biasを含む電気条件の評価は残します。
mission実行はlocal workerへ分離し、2秒heartbeat / 10秒ACK timeoutの診断構成で約86秒間health restart 0を確認しました。
さらにmission commandをDrive boot IDへ束縛しました。実行済みreply-loss command直後のDrive rebootでは、再接続後のretryを
新bootが拒否し、missionはindeterminate outcomeとして停止しました。state復元と自動resumeは提供しません。
2026-10-23のfollow-upではmission停止後もController health loopを継続し、新boot IDとguarded `:status`のsnapshotを記録しました。
snapshot後も両linkのtrafficを処理し、通常firmwareへ戻した3-step missionも完了しました。
さらにoperatorがControllerだけをresetし、保持中のDrive stateから新しいrequest IDとboot guardを使う別missionが完了しました。
これはstate reconciliationや自動resumeではありません。

## 今回は対象としないこと

- physical robot、motor、実 sensor の製作と driver
- real-time motion control と safety-critical control
- production-ready robotics software
- dynamic node discovery
- AVModbus core の general-purpose multidrop distribution support
- 機能検証より先に行う performance optimization
