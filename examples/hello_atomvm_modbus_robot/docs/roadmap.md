# ロードマップ

このexampleはhost-only simulationから2-node application、3-device Modbus multidrop、3-node distributionへ段階的に進みました。
現在は3台をphysical baselineとして固定し、N remote peersのscaleをhost modelで検証しました。技術的blockerを特定して
記録することも成果とします。

現在の実行方法は [サンプル README](../README.md)、設計判断は [ADR](adr/README.md)、実測結果は
[作業記録](worklog/README.md) を正とします。

## 現在地

| Stage | 状態 | 範囲 |
| --- | --- | --- |
| 0 | 完了 | host-only virtual rover |
| 1 | 完了 | 2-node mission と in-flight Drive reboot の境界を実機確認 |
| 2 | 完了 | 3-device standard Modbus multidrop、120-request soak、独立Server reboot |
| 3 | 実証完了 | 2 remote node の同時接続、Controller relay、複数 tick を実機確認 |
| 4 | 完了 | adaptive mission、readiness lease、reply-loss retry を実機確認 |
| 5 | 完了 | N remote peer host model、fairness、failure isolation、resource budget |
| 6 | 進行中 | startup / recovery matrix、global resource budget、長時間安定性 |

## Stage 0: ローカル仮想ローバーシミュレーション

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

## Stage 1: 2ノード分散ロボット

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

## Stage 2: 3台のModbusマルチドロップ

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

## Stage 3: 3ノード分散Erlang

- [x] drive と sensors に独立した sequence / ACK / session / byte-stream state を設計する
- [x] 1 本の physical UART を所有する process と polling policy を設計する
- [x] 複数の virtual UART stream を `serial_dist` / `net_kernel` に渡す方法を調査する
- [x] `controller <-> drive` と `controller <-> sensors` の connection を確立する
- [x] 両 remote node の registered process と message を交換する
- [x] Server node 間の message を controller で relay する必要があるか検証する
- [x] 片方の Server reboot 後に再接続し、もう一方の connection が継続することを確認する
- [x] Controller reboot 後に両 Server が再接続して application messaging を再開することを確認する
- [x] 基本疎通に dedicated carrier は不要と判断する
- [x] 最新の AtomVM v0.7 snapshotでもmulti-connection tick問題を確認し、local patch、test、3台実機結果を文書化する
- [x] 継続 application traffic と polling fairness の短時間 baseline を測定する
- [x] application traffic 中に Drive / Sensors を独立 reboot して recovery を確認する
- [x] concurrent producer の短時間 fairness baseline と moderate profile を検証する
- [x] 256+256 messagesの10分間soakでmemory / queue推移を検証する

完了条件は、controller と 2 台の remote node の genuine distribution を実証するか、必要な AtomVM / carrier
変更と blocker を再現可能な形で記録することです。基本疎通、3 role の独立 reboot recovery、60 application round trip の短時間
fairness baseline、traffic 中の両 remote reboot recovery、Sensors から Drive への Controller relay は 2026-10-19 に達成しました。
local AtomVM patch が必要な点は[既知の制約](limitations.md)として残します。AtomVM upstreamへのIssue / PRはこのexampleの
roadmapに含めず、対象v0.7 snapshotが更新されたときにlocal patchを再評価します。Modbus Server 同士が bus を直接駆動する構成は
仮定しません。2026-10-23には`18b35870`へpatch `a1069573`を適用したruntimeを3台へ導入し、2 connection、両remoteのprobe、
sensor-driven mission、mission後90秒の接続維持を確認しました。

## Stage 4: 仮想センサーと障害耐性

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

## 追試: 同時通信と信頼性（完了）

- [x] independent producer、application ACK window 1、bounded retryを実装する
- [x] overload、queue-full、half-open connection、reply lossの境界を記録する
- [x] readiness lease、remote-side distribution restart、mission worker分離を実装する
- [x] round-robin pollingで単一peer障害中も正常peerを維持する
- [x] rebootをまたぐ未確定commandを検出し、新bootでの自動再実行を止める
- [x] 256+256 traffic、ACK gap、queue、Controller heapを測定する
- [x] physical branch切断・再接続を反復する
- [x] 最新AtomVM v0.7 snapshotとlocal compatibility patchで再検証する

個別の条件と数値は[作業記録](worklog/README.md)、残る保証外の範囲は[既知の制約](limitations.md)を正とする。

## Stage 5: スケーラブルなマルチノードモデル

- [x] Controller transport setupをpeer descriptor list駆動にする
- [x] 3台をphysical integration baselineとして固定し、deviceを1台ずつ増やす試験を必須にしないと決める
- [x] 任意件数のpeer descriptorをhostで生成・検証する
- [x] N remote peerのround-robin fairnessとstarvationをdeterministic testで検証する
- [x] peer failure、overload、queue growth、recoveryをhost modelで再現する
- [x] 3台実測を基準にconnection数ごとのresource budgetを推定する

追加deviceは通常の完了条件にしない。host modelでは検証できない具体的なelectricalまたはruntime仮説が生じた場合だけtargeted
hardware testを行う。この判断は[ADR 0020](adr/0020-model-scale-on-host-instead-of-adding-devices.md)、test matrixと結果は
[実験計画](next-experiments.md)と[host model worklog](worklog/2026-10-24-scalable-multinode-host-model.md)に記録する。

1、2、3、8、32 remote peersでpoll回数の公平性と単一transactionを確認した。failed peerは正常peerをstarveさせないが、
timeoutはcycle latencyへ加算される。bounded queueはoverloadをrejectし、session replacementはstale queueを破棄する。
32 peersのconfigured payload limit 262,144 bytesは3台実測のminimum free heap 68,848 bytesを超えるため、current defaultを
そのままN streamsへ複製できるとは判断しない。

## Stage 6: 接続復旧とリソース管理

優先順位とPR分割は[実験計画](reliability-backlog.md)を正とする。最初のPRでは接続動作を変更せず、
[起動・復旧test matrix](startup-recovery-matrix.md)と観測eventを固定する。

- [x] Controller、Drive、Sensorsの全起動順序をhost matrixへ定義する
- [x] 初回handshake failureと接続後障害を別scenarioにする
- [x] opt-inのconnection lifecycle traceを追加する
- [x] 自動復旧、runtime blocker、証跡不足を区別するhost testを追加する
- [x] 3台で起動6順序matrixを実行する
- [x] 初回setup failureをDrive / Sensorsで再現する
- [x] 対象remoteだけのreset復旧中に他方を維持できるか実機確認する
- [x] 同一boot内で自動復旧しない具体的なruntime blockerを記録する
- [x] 初回readiness timeout後のbounded remote restartを追加する
- [x] Drive / Sensorsがboard resetなしで同一boot内復旧することを実機確認する
- [ ] Controller全体のglobal byte / chunk budgetを設計する
- [ ] 長時間通信断と1時間以上の安定性を実機測定する

このStageでは7秒setup timerの単純な延長、AVModbus core変更、専用`modbus_dist` carrier、4台目の常設を完了条件にしない。

## 今回は対象としないこと

- physical robot、motor、実 sensor の製作と driver
- real-time motion control と safety-critical control
- production-ready robotics software
- dynamic node discovery
- AVModbus core の general-purpose multidrop distribution support
- 機能検証より先に行う performance optimization
