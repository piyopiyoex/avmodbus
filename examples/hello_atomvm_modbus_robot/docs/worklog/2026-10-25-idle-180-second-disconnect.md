# Sensors branchのidle 180秒切断

## 目的

3台構成のidle接続中にSensors branchを約180秒外し、長時間通信断後のphysical transport、distribution、memory、
正常なDrive connectionへの影響を確認する。

## 条件

- 3 × Seeed Studio XIAO ESP32-C5
- AtomVM `release-0.7` snapshot `18b35870` + local patch `a1069573`
- 115,200 baud、96-byte chunk、20 ms poll、breadboard hub配線
- remote readiness ACK timeout 90秒、restart budget 1
- 3 roleで10秒periodic metricsとconnection traceを有効化
- Sensors branch取り外し記録: 2026-10-25 01:03:27 JST
- Sensorsの新FC-100 session検出: 01:06:46 JST

試験前に3台をresetした。取り外し指示への応答までに時間が空き、予定していた3-run trafficは先に完了したため、
この試験は通信中ではなくidle connectionのscenarioとして扱う。切断前campaignは64 messages / roleを3 runsすべて
`outcome=complete`で終了し、timeout 0、global rejection 0だった。

取り外しと復元を同じ自動timerでは操作していない。利用者の取り外し応答からControllerが新しいFC-100 sessionを検出するまで
約199秒であり、厳密な電気的切断時間ではない。

## 観測結果

観測した順序は次のとおりである。

1. Sensors transaction failureが増加し、Controllerは`net_tick_timeout`と`stale_detected`を記録した。
2. Driveは同じconnection IDでreadiness ACKを約30秒間隔で返し続けた。
3. Sensorsはreadiness ACK gap 118,381 msで`restart_started`となり、約0.2秒後に`restart_succeeded`を記録した。
4. branchはまだ外れていたため、新connectionの8秒readiness待機はtimeoutし、1回のrestart budgetを使い切った。
5. branch復元後、Controllerは新しいFC-100 sessionを検出し、Unit 2 pollingは復帰した。Sensors transaction failureは
   96で約10分間増加しなかった。
6. distribution handshakeは`unexpected <<"sok">>`と`unsupported_name <<>>`で失敗し、
   `remote_reconnected`と`recovery_verified`は記録されなかった。
7. Sensors free heapは復元直後の約83 KiBから継続的に低下した。FC-100 outgoing logはhandshake開始時の32 bytesと
   43 bytesだけで、transport queue増加を示す追加の`queued`行はなかった。
8. 新FC-100 session検出から約11分後、Unit 2 transaction failureが96から再び増加し、logger終了時に161となった。
   Sensorsのmemory metrics processは動作を続けていたが、FC-100 serverは応答不能になった。

| 指標 | 結果 |
| --- | ---: |
| Restart | 1 started / 1 succeeded / 0 failed |
| Restart budget exhausted | 1 |
| Remote reconnect / recovery verified | 0 / 0 |
| Sensors transaction failure | 17 → 161 |
| Drive transaction failure | 1 → 2 |
| Boot累積global queue high-water | 900 bytes / 14 chunks |
| Global rejection | 0 |
| Controller minimum free heap | 63,136 bytes |
| Drive minimum free heap | 77,344 bytes |
| Sensors minimum free heap | 14,428 bytes |
| Sensors minimum observed free heap | 23,552 bytes |

ControllerのDrive transaction failureは試験区間中に1から2へ1回増えたが、Drive readiness ACKとpoll成功は最後まで継続した。
`RobotSim.EnduranceReport`はmalformed 0、stale 1、restart started / succeeded 1、restart budget exhausted 1、
reconnect 0、`successful: false`と集計した。

## 判断

- 約199秒のidle切断後、physical Modbus pollingは一度復帰したが、distributionはboard resetなしに復旧しなかった。
- 正常なDrive connectionは維持され、障害をSensors側へ局在できた。
- Sensors free heapの継続低下後にFC-100 serverも応答不能になった。bounded FC-100 queueだけでは、この再接続失敗時の
  resource消費を制限できていない。
- free heap低下の所有processやAtomVM runtime内部の原因は、このlogだけでは確定していない。memory leakと断定せず、
  current v0.7 snapshotで再現したruntime blockerとして扱う。
- AtomVMへのIssue / PRは作成せず、このrepositoryの制約として記録する。

180秒scenarioの完了条件は「自動復旧」だけではなく、正常peerへの影響と明示的な回復不能状態を再現することを含む。
今回の結果で単発30 / 90 / 180秒の境界測定は完了した。この時点の後続課題だった同一bootでの短時間切断反復と
約1時間の安定性試験も、別scenarioとして実施済みである。
