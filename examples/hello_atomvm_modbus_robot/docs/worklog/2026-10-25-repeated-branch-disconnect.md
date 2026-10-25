# Sensors branchの同一boot反復切断

## 目的

3台構成の同一bootでSensors branchの短時間切断・復帰を3回反復し、distribution connection、message delivery、
restart budget、正常なDrive、queueとmemoryに状態が累積するか確認する。

## 条件

- 3 × Seeed Studio XIAO ESP32-C5
- AtomVM `release-0.7` snapshot `18b35870` + local patch `a1069573`
- 115,200 baud、96-byte chunk、20 ms poll、breadboard hub配線
- Controller: Drive / Sensors各64 messagesを3 runs、64-byte payload、run間idleなし
- traffic timeout 600秒、application ACK timeout 240秒、retry 1
- remote readiness ACK timeout 90秒、restart budget 1
- 3 roleで10秒periodic metricsとconnection traceを有効化
- SensorsのA/B branchだけを切断し、USB cableと電源は維持

試験前に3台をresetした。Drive connection IDは`3244749151`、Sensors connection IDは`3706994990`だった。
切断と復元を自動timerおよびserial logと共通の時計では記録していないため、Controllerの連続transaction timeoutと
Sensors readiness ACK gapを観測値として使う。これらは電気的切断時間そのものではない。

## 除外した試行

最初の試行では2回目にSensorsのUSB cableを30秒外したため、board rebootとboot identity変更が混入した。この試行は
branch切断の反復結果に含めず、3台をresetしてからA/B branchだけでやり直した。

## 観測結果

3回ともSensorsは同じconnection IDのまま復帰し、`stale_detected`、remote restart、restart budget消費、
FC-100 session変更を記録しなかった。切断ごとの観測値は次のとおりである。

| Cycle | Traffic run | Sensors連続timeoutの概算 | Readiness ACK gap | Sensors transaction failure増分 | 結果 |
| --- | ---: | ---: | ---: | ---: | --- |
| 1 | 1 | 約60秒 | 76,277 ms | 30 | 同じconnectionで復帰 |
| 2 | 2 | 約40秒 | 73,226 ms | 20 | 同じconnectionで復帰 |
| 3 | 2 | 約32秒 | 49,211 ms | 16 | 同じconnectionで復帰 |

Cycle 1と2は30秒を狙った操作だったが、serial log上の連続timeout区間はそれより長かった。手動操作、進行中transaction、
poll順序を分離できないため、正確な30秒試験とは扱わない。Cycle 3は約2秒のtransaction timeout 16件と整合する
約30秒の障害区間だった。いずれも90秒のremote health timeoutには達しなかった。

### Application traffic

| Run | Fault | Drive | Sensors | Missing / duplicates / invalid | Elapsed |
| --- | --- | ---: | ---: | ---: | ---: |
| 1 | Cycle 1 | 64 / 64 | 64 / 64 | 0 / 0 / 0 | 331,974 ms |
| 2 | Cycle 2、3 | 64 / 64 | 64 / 64 | 0 / 0 / 0 | 340,606 ms |
| 3 | なし | 64 / 64 | 64 / 64 | 0 / 0 / 0 | 285,938 ms |

run 1のDrive / Sensors transaction failureは1 / 30、run 2は1 / 36、run 3は0 / 1だった。Driveの単発timeoutを含め、
正常peerへの影響が完全に0だったとは扱わない。ただしDriveは同じconnectionでmessage deliveryを継続し、全runを完了した。

run 2の途中でserial loggerを終了してしまったため、boardをresetせず約22秒後に再接続した。application runとconnectionは
継続しており、後半を別log fileへ保存した。2組のlogを`RobotSim.EnduranceReport`で個別に集計し、いずれもmalformed line 0、
後半はcampaign `complete run=3/3`、`successful: true`だった。

### Resource

| 指標 | 結果 |
| --- | ---: |
| Boot累積global queue high-water | 906 bytes / 14 chunks |
| Global rejection | 0 |
| Controller minimum free heap | 62,600 bytes |
| Drive minimum free heap | 77,384 bytes |
| Sensors minimum free heap | 81,096 bytes |
| Restart / reconnect event | 0 / 0 |

各runのsettled metricsでは最終的にglobal queueが0 bytes / 0 chunksへ戻った。約16分のcampaign中に3 roleの
minimum free heap watermarkは正のまま維持された。この短時間試験だけからmemory leakがないとは判断しない。

## 判断

- 90秒remote health timeoutより短い3回の障害では、Sensorsはrestart budgetを消費せず同じdistribution connectionで復帰した。
- faultを含むrunも欠損・重複・順序違反なしで完了し、切断後のrun 3も完全配送した。
- 3回の反復でqueue拒否、session変更、connection eventの累積は観測しなかった。
- Drive connectionは維持されたが、faultを含むrunごとに単発transaction timeoutが1件あったため、正常peerへの無影響は保証しない。
- この結果を90秒以上の切断へ外挿しない。長時間切断ではrestart budget消費、再接続失敗、resource低下を別試験で確認している。
- 操作時間の精密測定ではないため、今後時間境界そのものを比較する場合は外部timerの時刻をlogへ入力する仕組みが必要である。

これにより、同一peerの短時間切断・復帰を同一bootで反復するscenarioは完了とする。この時点の次の実機課題だった
active / idleを交互にする約1時間の安定性試験も、
[別worklog](2026-10-25-one-hour-active-idle-endurance.md)として完了した。
