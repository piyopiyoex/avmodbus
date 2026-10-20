# 次の実験: concurrent traffic と障害復旧

2026-10-20 の 3-node snapshot を baseline とする follow-up 計画と進捗記録です。
Stage 0–4 の完了結果は[ロードマップ](roadmap.md)と[作業記録](worklog/README.md)を正とします。

## 実装した基盤

- `ROBOT_MULTINODE_TRAFFIC_SAMPLES=0` のとき従来動作を変更しない opt-in probe
- Drive / Sensors に独立 producer process を起動する message
- Controller に独立 collector process を起動し、既存の readiness loop を塞がない
- run ID、role、sequence、payload を照合する bounded host-side stats
- Controller clock だけで計算する role 別 duration、throughput、completion skew、delivery ratio gap
- Unit別 transaction count / failure / latency、queue high-water、実行前後と30秒後の heap snapshot
- 256 sample / role、128-byte payload の明示的上限と run timeout
- host test で独立 producer、重複、順序違反、missing、無応答 timeout を確認する構成
- started / sample / finishedごとのapplication ACKとrole別in-flight window 1
- ACK timeout時のsame-run / same-sequence bounded retry
- connection ID付きreadiness ACKによるapplication traffic非依存のremote health
- board boot単位のrestart上限と、`net_kernel.stop/0`後のbounded shutdown待ち

送信は各 remote process が個別に開始しますが、wire 上の Modbus RTU request は
**Controller が単一 client として順番に送る**既存仕様から変更しません。

## 実機試験 profile

最初は 3 台の XIAO ESP32-C5 と AtomVM local patch を使い、次の順に試します。
各 role の `MIX_ENV=prod` firmware を新しい source から build し直します。

| Profile | Drive interval | Sensors interval | Count / role | Payload |
| --- | ---: | ---: | ---: | ---: |
| baseline | 2000 ms | 1000 ms | 5 | 16 bytes |
| moderate | 1000 ms | 500 ms | 10 | 32 bytes |
| exploratory overload | 250 ms | 250 ms | 20 | 64 bytes |
| longer run、flow controlなし | 500 ms | 500 ms | 64 | 64 bytes |
| longer run、ACK window 1 | 500 ms | 500 ms | 64 | 64 bytes |
| extended run、ACK window 1 | 500 ms | 500 ms | 256 | 64 bytes |

6 profile は 2026-10-20 に実施済みです。flow controlなしのlonger runはsession resetでtimeoutし、ACK window 1の64+64と
256+256 profileは完全配送しました。

記録する項目:

- 役割別の `received / expected`、missing、duplicate、invalid、out-of-order
- Collector の run duration、role 別 throughput / max interarrival gap、role 間の delivery ratio gap / completion skew
- `MODBUS_TRACE_TRANSACTIONS` / `MODBUS_TRACE_QUEUE` を有効にした別 run の物理 transaction、queue 観察
- readiness lease、再接続、tick timeout、heap / memory、重い workload 時の timeout

Controller と remote の monotonic clock は同期していません。producer の送信時刻との差から
one-way latency を算出してはいけません。RTT 計測は既存の echo probe を別途利用します。

## 成功条件と停止条件

- baseline: Drive / Sensors ともに `received == expected`、`missing == 0`、`invalid == 0`、かつ
  `active_overlap_ms > 0` で両 producer の受信 window が重なること。
- moderate: 接続が継続し、role 間で極端な starvation がないことを実測で評価する。
- overload: delivery の遅延や失敗を記録する。完全配送を前提としない。
- `net_tick_timeout`、queue-full、OOM、継続的な timeout が発生したら負荷を上げずに原因を記録する。

`finished == false` / `outcome == :timeout` は collector が期限内に送信終了通知を
観測できなかったことを示します。送信済み message の durable delivery を保証しません。

## 2026-10-20 の結果

3 台の XIAO ESP32-C5、shared two-wire RS485、115,200 baud、96-byte FC-100 chunk で各 profile を1 run実施しました。

| Profile | Drive | Sensors | Elapsed | Active overlap | Completion skew | Delivery ratio gap |
| --- | --- | --- | ---: | ---: | ---: | ---: |
| baseline | 5 / 5、581 milli-msg/s | 5 / 5、1078 milli-msg/s | 10,588 ms | 4,448 ms | 4,145 ms | 0‰ |
| moderate | 10 / 10、1042 milli-msg/s | 10 / 10、1131 milli-msg/s | 11,593 ms | 8,655 ms | 937 ms | 0‰ |
| overload | 20 / 20、803 milli-msg/s | 20 / 20、750 milli-msg/s | 29,769 ms | 23,579 ms | 1,310 ms | 0‰ |
| longer、flow controlなし | 23 / 64 | 24 / 64 | 300,001 ms timeout | unavailable | unavailable | 16‰ |
| longer、ACK window 1 | 64 / 64、401 milli-msg/s | 64 / 64、404 milli-msg/s | 163,039 ms | 156,298 ms | 3,114 ms | 0‰ |
| extended、ACK window 1 | 256 / 256、409 milli-msg/s | 256 / 256、409 milli-msg/s | 627,792 ms | 623,957 ms | 1,029 ms | 0‰ |

baseline の Drive max interarrival は 2,136 ms、Sensors は795 msでした。moderate ではそれぞれ1,195 ms、824 msでした。
これは Controller 受信時刻による短時間の観測値で、producer の one-way latency や長期的な公平性保証ではありません。
詳細、firmware size、起動時に見つかった managed client handle の互換性修正は
[実機 worklog](worklog/2026-10-20-concurrent-traffic.md)に記録しています。

overload では Drive 69 success / 1 timeout、Sensors 70 success / 0 failureでした。Controller側queue high-water はDrive 261 bytes /
4 chunks、Sensors 149 bytes / 2 chunksでした。longer runでは両 carrier session が再生成され、distributionは再接続しましたが
producerは復元されずtimeoutしました。30秒後のController側queueは両方0、free heapは約86 KBでした。

3台同時consoleの診断runではSensors側で`queue rejected ... reason=:queue_full`、直後に
`{serial_write_error, queue_full}`、Controller側でpeer session changeと`{serial_read_error, closed}`の順に発生しました。
500 ms producerの生成速度がshared busの排出速度を上回り、remote outgoing queueを飽和させたことが直接原因です。
[overload / longer run worklog](worklog/2026-10-20-overload-and-long-run.md)も参照してください。

application ACKでroleごとのin-flight windowを1にした再試験では、missing / duplicate / out-of-order / invalid 0で両role 64 / 64を
完了しました。queue-full、session change、ACK timeoutは発生せず、30秒後のController側queueは両方0でした。詳細は
[ACK flow-control worklog](worklog/2026-10-20-ack-flow-control.md)を参照してください。

同じflow-controlled probeでSensorsのFC-100 responseを180回連続して破棄したところ、未確認のsequence 7に対する
same-sequence retryは10秒ごとに動作しました。しかしControllerだけが`net_tick_timeout`で接続を閉じ、requestを受信していたSensors側は
古いdistribution connectionを保持しました。response破棄終了後はphysical pollingとcarrier byte deliveryが復帰したものの、session changeや
distribution reconnectは発生せず、producerは12回のretryを使い切って停止しました。詳細は
[response blackout worklog](worklog/2026-10-20-response-blackout.md)を参照してください。

follow-upではSensors producerの最初のACK timeoutをlocal ownerへ通知し、Sensors側の`net_kernel`だけをstop / restartした。
ControllerのDrive connectionを維持したままSensorsが再接続し、同じrun ID / sequence 2からproducerを再開した。16+16 messagesは
missing / duplicate / out-of-order / invalid 0、63,171 msで完了した。詳細は
[response blackout recovery worklog](worklog/2026-10-20-response-blackout-recovery.md)を参照してください。

さらにreadiness heartbeatへconnection ID付きACKを返し、remote側でACK期限を判定するopt-in health detectorを追加した。
application trafficを無効にした状態でも、Sensorsはresponse blackout開始後にACK欠落28,524 msを検出してdistributionを再起動した。
ControllerはDrive connectionを維持し、Sensorsのreconnect後に両roleのprobeを完了した。faultが再armされた2回目のblackoutでは
boot単位の上限によりrestartせず、restart stormを抑止した。最初の試行で`net_kernel.stop/0`返却後も旧processが残るraceを再現したため、
登録解除をbounded pollしてからstartする。詳細は
[idle connection recovery worklog](worklog/2026-10-20-remote-readiness-health.md)を参照してください。

256+256 extended runは10分27.792秒でcompleteし、missing / duplicate / out-of-order / invalidは両roleとも0だった。Unit別transaction
failureは各2回、queue high-waterはDrive 279 bytes / 4 chunks、Sensors 162 bytes / 2 chunksで、30秒後は両queueとも0になった。
Controllerのfree heapは開始時約89 KB、settled時約85 KB、minimum watermark 70,736 bytesだった。詳細は
[extended long-run worklog](worklog/2026-10-20-extended-flow-controlled-run.md)を参照してください。

2026-10-21のpaired-wire配線ではSensorsまたは右端DriveのA/Bを外すと残るpeerも停止し、link復帰だけでは2 linkが完全復旧しなかった。
breadboard上のcontinuous trunkとnode別branchへ変更した初回試験ではDriveを維持できたが、反復試験でshared Clientの
head-of-line deadline starvationを発見した。各adapterが独立してpollすると、到達不能なUnit 2のqueue待ち中にUnit 1のdeadlineも
消費され、正常なDriveまで`net_tick_timeout`になった。

pollをround-robin schedulerで直列に開始する変更後は、2回のSensors branch切断中にUnit 2が約2秒timeoutを繰り返しても、Unit 1は
約180–225 ms、failure 0で継続した。未使用restart budgetでのrunはACK欠落48,470 msでSensorsを自動再起動し、branch復帰後に
Controller / Sensorsの手動resetなしでSensors reconnectと両peerへのprobeを完了した。handshakeは複数回retryしており、収束時間の上限は
まだ測定していない。

25,000 msのhealth timeoutは抜線前の通常mission中にfalse positiveとなったため、負荷を考慮せず短く設定できない。breadboard試験も
外付けterminationなしの短いbench配線における少数runであり、復旧時間の上限や一般的な電気条件を示さない。詳細は
[物理RS485切断worklog](worklog/2026-10-21-physical-rs485-disconnect.md)を参照してください。

## その次に取り組む候補

1. health detectorのtimeoutを負荷profile別に評価し、25秒で観測したfalse positiveの安全余裕を定量化する。
2. round-robin schedulerでbreadboard branch切断・復帰をさらに反復し、handshake収束時間、memory / queueのsettlingを測定する。
3. response faultの再armを避けるone-shot診断方法を用意し、recovery後のsettled queue / memoryを測定する。
4. Drive reboot 中の未確定 movement command を reconcile する。volatile state と request cache を越える exactly-once を安易に約束しない。
5. Mission 実行を別 process に分離し、Controller readiness lease が同期 request 中も動くようにする。
6. AtomVM の個別disconnect API、multi-connection tick、setup retry、remote process monitorをupstream follow-upする。
7. 3 remote / 4 device への拡張は、3 device fairness と memory の限界を測定した後に検討する。

AVModbus core と wire protocol は変更しません。既存 carrier には観測専用 metrics API と Unit ID 付き trace だけを追加しています。
