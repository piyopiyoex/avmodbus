# Stage 9 非対称response blackout実機比較

## 目的

ControllerからのFC-100 requestはSensorsへ届く一方、Sensorsのresponseだけを破棄する障害で、current / deferred recovery policyを
比較する。既存のtransport activity signalが非対称障害を扱えるか、3台の実機で確認する。

## 条件

| 項目 | 値 |
| --- | --- |
| Device | Seeed Studio XIAO ESP32-C5 × 3 |
| Bus | 2-wire RS485、Controller 1台、Drive Unit 1、Sensors Unit 2 |
| AtomVM | release-0.7 `18b35870` + local patch `a1069573` |
| UART | 115,200 baud |
| Poll / chunk | 20 ms / 96 bytes |
| Fault対象 | SensorsのFC-100 response |
| Fault | 起動60秒後から180 responsesを破棄 |
| Remote ACK timeout | 90,000 ms |
| Restart上限 | 1回 |
| Application traffic | 無効 |

Sensorsだけで`MODBUS_FAULT_DROP_RESPONSES=180`、`MODBUS_FAULT_MIN_PAYLOAD_BYTES=0`、
`MODBUS_FAULT_AFTER_MS=60000`、`MODBUS_FAULT_REARM_ON_RESTART=false`、`ROBOT_MULTINODE_EXCHANGE_TRACE=true`を有効にした。
Currentは`ROBOT_MULTINODE_DEFER_RESTART_UNTIL_TRANSPORT_READY=false`、deferredは`true`とした。Controllerでは
`MODBUS_TRACE_TRANSACTIONS=true`を有効にした。共通設定は[Stage 9試験計画](../stage-9-asymmetric-response-blackout.md)を参照する。

各runの前にController、Drive、Sensorsを順番にresetした。正式な観測区間は最後のSensors resetから開始し、準備中に発生したfaultは
結果へ含めていない。USB再列挙時に`/dev/ttyACM*`が生成されない場合は、`systemd-udevd`の再起動と`udevadm trigger`で復旧した。

## 結果

| Policy | Run | Blackout | `response_returned`からpolicy判断 | 180秒以内のdistribution復旧 | Drive |
| --- | ---: | ---: | ---: | --- | --- |
| Current | 1 | 83.590秒 | 14.702秒後にrestart | 成功、probeまで25.120秒 | 維持 |
| Current | 2 | 83.670秒 | 14.369秒後にrestart | 成功、probeまで28.016秒 | 維持 |
| Deferred | 1 | 83.471秒 | 12.428秒後にrestart保留 | 失敗 | 維持 |
| Deferred | 2 | 83.286秒 | 14.863秒後にrestart保留 | 失敗 | 維持 |

各runで180件の`request_accepted`と`response_dropped`が同じ`exchange_id`で対応し、fault終了後の最初のrequestで
`response_returned`を1件記録した。ControllerのUnit 2 transactionもその後成功へ戻った。

Controllerはfault終了前にSensorsをstaleと判定した。Current policyはController transactionが成功へ戻った後にACK timeoutで
distributionを1回restartし、readiness ACK、Controller再接続、Sensors / Drive両probeまで完了した。Deferred policyはrestart budgetを消費しなかったが、
`transport_ready`が発生せず、2回とも観測終了までSensors distributionは復旧しなかった。

観測したminimum free heapは次の範囲だった。

| Role | Minimum free heap |
| --- | ---: |
| Controller | 68,520–69,008 bytes |
| Drive | 79,272–80,752 bytes |
| Sensors | 81,628–82,336 bytes |

Global queue rejectionは4 runsすべて0だった。Deferredの待機中もSensors free heapの単調減少は見られなかった。

## 判断

Response blackout中もSensorsはrequestを受理するため、request受理時刻を使うobserverには長時間gapが生じない。
そのためStage 7–8のdeferred policyは物理response復帰後もrestartを解放できなかった。

`response_returned`もAVModbus Serverへ値を返した境界にすぎず、Controllerへの到達を保証しない。非対称障害の復旧判定には、
Controllerがresponseを受信したことを示すcarrier-levelの確認が必要である。Stage 9ではsignalやwire protocolを追加せず、
current policyを既定、deferred policyをopt-inのまま維持する。

この結果は診断用fault injectionによる2 runs / policyの探索的な比較であり、任意のRS485障害に対する成功率ではない。

## 証跡

測定には次の一時ログを使用した。これらはrepositoryへ含めない。

```text
/tmp/modbus-stage9-current-r{1,2}-{controller,drive,sensors}.log
/tmp/modbus-stage9-deferred-r{1,2}-{controller,drive,sensors}.log
```
