# 1回限りの応答障害と安定化確認 — 2026-10-23

## 目的

Sensorsのresponse blackoutからremote distributionを再起動した後、replacement adapterで同じfaultを再armせず、application trafficの
回復と30秒後のqueue / memory settlingを測定する。

## 実装とhost検証

`MODBUS_FAULT_REARM_ON_RESTART=false`をdefaultとして追加した。initial Server adapterには設定したdrop countを渡し、remote
distribution restart後のadapterには0を渡す。`true`を明示すると従来どおり再armする。device rebootでは再びinitial adapterになる。

host testではone-shotと明示的rearmの両方を確認した。最終確認は次のとおりである。

- root project: 228 tests + 6 properties、failure 0
- 既存disterl example: 67 tests、failure 0
- robot example: 72 tests、failure 0
- Drive / Sensors / Controller: `mix atomvm.check`と`mix atomvm.packbeam`に成功

## 実機条件

- 3 × Seeed Studio XIAO ESP32-C5
- breadboard railによるcontinuous A/B trunkとnode別branch、共通GND
- 115,200 baud、FC-100 chunk payload 96 bytes
- AtomVM v0.7.0-beta.0と既存multi-connection local patch
- Controller: 16 messages / role、64-byte payload、in-flight window 1、ACK timeout 10秒、retry 12回
- Sensors: response 180回破棄、最小payload 0、起動75秒後に開始、rearm無効
- Sensors remote health: announce 10秒、ACK timeout 45秒、restart上限1回 / boot
- Controller診断image 266,812 bytes、Sensors診断image 262,180 bytes

## 条件調整で分かったこと

最初のrunはfault開始を60秒、health timeoutを25秒とした。fault開始とControllerのtraffic開始が重なり、Sensors向け
`start_multinode_traffic` message自体がblackout中に未配送となった。Driveは16 / 16を完了したがSensorsは`started=false`、0 / 16で
collectorが300,006 ms後にtimeoutした。distributionは再接続しても、一度だけ送るapplication start messageを復元しない。

ただしone-shotとsettlingは確認できた。faultは39 response破棄、ACK gap 28,286 msでrestartし、replacementでは再発しなかった。
timeout直後のSensorsは636 success / 29 failure、queue 0だった。30秒後は704 success / 29 failure、queue 0、free heap
82,184 bytes、minimum watermark 77,032 bytesだった。

fault開始90秒、health timeout 25秒のrunは起動区間をconsoleで取得できず、期待したfaultを観測できなかったため測定対象から除外した。
既知のfalse positive marginを避け、最終runではhealth timeoutを45秒、fault開始を75秒とした。

## 最終runの時系列

| 時刻 | 観測 |
| --- | --- |
| 09:49:56.664 | traffic run `102034787`を開始 |
| 09:50:14.567 | Sensorsが最初のFC-100 responseを破棄。sequence 6が未確認となる |
| 09:50:24.637 | Sensors producerがsequence 6のACK timeout retryを開始 |
| 09:50:57.900 | ACK gap 48,184 msでSensors distribution restartを開始 |
| 09:50:58.047 | replacement Server adapterをsession `3329241614`でopen |
| 09:51:00.353 | Controllerがpeer session changeを検出 |
| 09:51:04.101 | ControllerがSensors reconnectを受信 |
| 09:51:11.216 | Sensors / Drive両方のrecovery probeが成功 |
| 09:51:41.969 | Drive / Sensors 16 + 16 trafficがcomplete |
| 09:52:12.218 | 30秒settled metricsを記録 |
| 09:52:39.914 | 監視終了。replacementで2回目のfaultなし |

restart前にSensors producerはsequence 6で4回timeoutし、restart後のretry remaining 8から再開した。Drive distributionは維持された。

## アプリケーションの結果

| Metric | Drive | Sensors |
| --- | ---: | ---: |
| expected / received | 16 / 16 | 16 / 16 |
| missing / duplicate | 0 / 0 | 0 / 0 |
| out-of-order / invalid | 0 / 0 | 0 / 0 |
| duration | 45,009 ms | 103,142 ms |
| throughput | 355 milli-msg/s | 155 milli-msg/s |
| max interarrival | 3,040 ms | 55,205 ms |

run elapsedは105,285 ms、active overlapは44,763 ms、completion skewは58,379 ms、delivery ratio gapは0‰だった。

## キューとメモリーの測定

| Phase / role | success / failure | queue bytes / chunks | max queue bytes / chunks | free heap | minimum |
| --- | ---: | ---: | ---: | ---: | ---: |
| complete / Drive | 227 / 0 | 0 / 0 | 174 / 2 | 83,000 | 76,656 |
| complete / Sensors | 125 / 103 | 135 / 2 | 504 / 8 | 81,304 | 76,656 |
| settled / Drive | 295 / 0 | 0 / 0 | 174 / 2 | 82,556 | 76,656 |
| settled / Sensors | 192 / 103 | 0 / 0 | 504 / 8 | 82,020 | 76,656 |

replacement adapter起動から監視終了までは約101秒で、75秒のfault delayを超えている。`fault dropped`の2回目はなく、failure countも
103から増えなかった。

## 通常構成への復元確認

SensorsとControllerをfault、traffic、remote health無効の通常firmwareへ戻した。imageはSensors 262,184 bytes、Controller
266,104 bytesだった。Drive / Sensors両接続、両probe、3-step mission、final statusが成功した。Driveはresetしていないためstateを保持し、
最終stateは`{x_mm: 200, y_mm: 400, heading_deg: 180}`だった。

## 結論

one-shot policyにより、1回のblackout、Sensorsだけのdistribution restart、同一producerの再開、完全配送、queue drainを1 runで
測定できた。これはfault injectionを再現可能にする診断上の改善であり、distribution reconnectによる任意のapplication messageの
durable deliveryを保証しない。特にworkload start messageにはACKまたはbounded retryが必要である。
