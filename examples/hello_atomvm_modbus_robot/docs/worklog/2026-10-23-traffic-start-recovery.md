# Blackout中のtraffic start recovery — 2026-10-23

## 目的

Sensors linkのresponse blackout中に未配送となるconcurrent traffic startを、application ACKとbounded retryでdistribution再接続後に
開始できるか検証する。ACK lossによる同一runのproducer重複起動も防ぐ。

## 実装とhost検証

Controllerはrole別のstart workerから`run_id`付きstartを送り、remoteのstart ACKを待つ。timeout時は既存の
`ROBOT_MULTINODE_TRAFFIC_ACK_TIMEOUT_MS`と`ROBOT_MULTINODE_TRAFFIC_ACK_RETRIES`を使って同じ要求を再送する。remoteは最後に
受理したrun IDをdistribution restartをまたいで保持し、duplicate startにはACKだけを返す。

blackoutとの時刻関係を固定するため、mission完了後のtraffic開始をnonblocking timerで遅延する
`ROBOT_MULTINODE_TRAFFIC_START_DELAY_MS`を追加した。

hostでは次を確認した。

- robot example: 74 tests、failure 0
- 最初のstartを破棄しても2回目の送信後に両roleがcompleteする
- start ACK retry上限を使い切った無応答roleはcollector全体をhangさせずtimeoutする
- 同じrun IDはduplicate、異なるrun IDはnewと分類する
- root project: 228 tests + 6 properties、failure 0
- 3 roleのAtomVM compatibility checkとPackBEAM buildに成功

## 実機条件

- 3 × Seeed Studio XIAO ESP32-C5
- breadboard railのcontinuous A/B trunk、node別branch、共通GND
- AtomVM v0.7.0-beta.0と既存multi-connection local patch
- 115,200 baud、FC-100 chunk payload 96 bytes
- Controller: 16 messages / role、64-byte payload、interval 500 ms、window 1
- Controller: traffic start delay 25秒、ACK timeout 10秒、retry 12回、run timeout 300秒
- Sensors: 起動60秒後から180 responseを破棄、最小payload 0、restart後のfault rearmなし
- Sensors remote health: announce 10秒、ACK timeout 45秒、restart上限1回 / boot

## 結果

run `2239607979`はSensors blackout中に開始した。Drive producerは開始したが、Sensors start ACKは複数回timeoutし、少なくとも
`remaining=9`まで同じrun IDを再送した。Sensorsはreadiness ACK gap 48,266 msでdistributionを再起動し、replacement adapterを
session `2779663707`でopenした。Controllerはpeer session changeを検出し、Sensors reconnectと両peerのrecovery probeを完了した。

再接続後のstart retryでSensors producerが開始し、runは105,020 msでcompleteした。

| Metric | Drive | Sensors |
| --- | ---: | ---: |
| expected / received | 16 / 16 | 16 / 16 |
| missing / duplicate | 0 / 0 | 0 / 0 |
| out-of-order / invalid | 0 / 0 | 0 / 0 |
| duration | 46,873 ms | 50,107 ms |
| sample span | 42,426 ms | 43,614 ms |
| throughput | 341 milli-msg/s | 319 milli-msg/s |
| max interarrival | 3,354 ms | 3,333 ms |

Sensors producerの開始はDriveより51,778 ms遅れた。active overlapは0 ms、completion skewは55,012 msだった。これは両producerが
同時に開始したbaselineではなく、未配送startが回復後に遅れて開始したことを示す。sampleのmissing、duplicate、order errorはない。

## Queueとmemory

| Phase / role | success / failure | queue bytes / chunks | max queue bytes / chunks | free heap | minimum |
| --- | ---: | ---: | ---: | ---: | ---: |
| complete / Drive | 223 / 0 | 0 / 0 | 199 / 3 | 82,796 | 75,528 |
| complete / Sensors | 128 / 96 | 137 / 2 | 995 / 15 | 81,068 | 75,528 |
| settled / Drive | 291 / 0 | 0 / 0 | 199 / 3 | 82,976 | 75,528 |
| settled / Sensors | 195 / 96 | 0 / 0 | 995 / 15 | 82,784 | 75,528 |

complete時に残ったSensors queueは30秒後に0へdrainした。Drive transaction failureは0で、Sensors fault中は96 failureだった。

## 通常構成への復元確認

3 roleをfault、remote health、traffic無効の通常構成でcheck、pack、flashした。imageはDrive 263,560 bytes、Sensors 263,532 bytes、
Controller 267,220 bytesだった。同期reset後に2本のdistribution connection、両peerのprobe、3-step sensor mission、final statusが
成功した。最終rover stateは`{x_mm: 200, y_mm: 0, heading_deg: 90}`だった。

## 結論

blackout中に一度だけ送って失われていたtraffic startは、role別ACKとbounded retryによってdistribution再接続後に配送できた。
remote側run ID guardによりACK loss時の重複起動を抑止する。これはexampleのdiagnostic workload lifecycleであり、device rebootを
またぐdurable job deliveryやexactly-once実行を保証しない。
