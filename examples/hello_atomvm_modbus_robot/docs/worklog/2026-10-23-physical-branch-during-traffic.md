# 同時通信中のSensors分岐切断・復旧 — 2026-10-23

## 目的

breadboard上のcontinuous A/B trunkとnode別branchを使い、Drive / Sensorsが同時にapplication trafficを送っている間に
Sensors branchだけを物理的に切断する。次を同じrunで確認する。

- 到達不能なUnit 2がshared busを占有してもDrive trafficが継続する
- Sensorsのremote healthが停止したdistributionを検出して再起動する
- application ACK retryが未確認sequenceを保持し、再接続後にproducerを再開する
- 両roleが全messageを完了し、queueがsettling後にdrainする

idle時の物理切断とround-robin schedulerの導入経緯は
[物理RS485切断・再接続](2026-10-21-physical-rs485-disconnect.md)を参照する。

## 実機条件

- 3 × Seeed Studio XIAO ESP32-C5
- breadboard railのcontinuous A/B trunk、node別branch、共通GND
- AtomVM v0.7.0-beta.0と既存multi-connection local patch
- 115,200 baud、FC-100 chunk payload 96 bytes
- Controller: 128 messages / role、64-byte payload、両interval 500 ms
- Controller: traffic開始delay 60秒、run timeout 600秒、settling 30秒
- Controller: application ACK timeout 10秒、retry 90回、in-flight window 1
- Sensors: announce 10秒、remote health有効、ACK timeout 30秒、restart上限1回 / boot
- Drive: remote health restart無効、readiness ACK gap trace有効

試験時のportとBase MACは次の対応だった。port番号は再列挙で変わり得るため、MACをroleの識別に使った。

| Role | Port | Base MAC | Unit ID |
| --- | --- | --- | ---: |
| Sensors | `/dev/ttyACM0` | `10:BD:A3:CF:09:04` | 2 |
| Drive | `/dev/ttyACM1` | `38:44:BE:A5:04:DC` | 1 |
| Controller | `/dev/ttyACM2` | `38:44:BE:A5:05:14` | client |

## 予備runで修正した試験手順

最初の長時間runではcollectorの全体期限がoperator待ちとhandshake retryを含めて15分だったため、物理linkとdistributionが
復旧しても、その約30秒前にcollectorがtimeoutした。全体期限は障害中に停止せず、baseline traffic、切断保持、handshake、
復旧後の残りtrafficをすべて含む。

次のrunでは存在しない`ROBOT_MULTINODE_TRAFFIC_RETRIES`と短縮したinterval名を指定したため、実際には既定のretry 1回、
Drive interval 2秒、Sensors interval 1秒で起動した。起動logの`ack_retries=1`と実測時間から誤りを確認した。正しい変数名は
`ROBOT_MULTINODE_TRAFFIC_ACK_RETRIES`、`ROBOT_MULTINODE_TRAFFIC_DRIVE_INTERVAL_MS`、
`ROBOT_MULTINODE_TRAFFIC_SENSORS_INTERVAL_MS`である。

さらに同じSensors bootで試験を繰り返すと、前runでrestart上限1回を使用済みだったため
`remote health restart budget exhausted`となった。これはrestart stormを防ぐ設計どおりの動作である。最終run前に3台を
ハードリセットし、producer、run guard、boot単位restart countを初期化した。

## 切断とdistribution復旧

最終run `877817280`のtraffic開始後、SensorsのRS485 A/B branchだけを外し、USB電源と共通GNDは維持した。

- Sensors producerはsequence 7のACK待ちとなり、retry残数90から再送を継続した
- Drive producerも一時的にACK待ちとなったが、Drive connectionとUnit 1 transactionは維持された
- Sensorsは最後のreadiness ACKから38,388 ms後にtimeoutを検出した
- Sensorsはdistribution connection `3021945011`を停止し、新connection `3810119234`を開始した
- replacement carrier sessionは`399026492`となった
- restart時の`{serial_read_error, closed}` crash reportは既知のteardown表示である

distribution再起動を確認した後にSensors branchを同じ極性で戻した。handshakeは一時的なtimeoutとchallenge retryを経て収束し、
ControllerはSensors reconnect、Sensors probe、切断中も維持されたDrive probe、`recovery complete`の順に記録した。
Sensors producerは同じrun IDとsequence 7から再開した。

## 通信結果

runは451,811 msで`outcome=:complete`となった。

| Metric | Drive | Sensors |
| --- | ---: | ---: |
| expected / received | 128 / 128 | 128 / 128 |
| missing | 0 | 0 |
| duplicate | 3 | 0 |
| out-of-order / invalid | 0 / 0 | 0 / 0 |
| duration | 424,123 ms | 448,093 ms |
| sample span | 419,642 ms | 443,729 ms |
| throughput | 301 milli-msg/s | 285 milli-msg/s |
| max interarrival | 21,366 ms | 72,741 ms |

start skewは246 ms、active overlapは423,877 ms、completion skewは24,216 ms、delivery ratio gapは0‰だった。
Driveのduplicate 3件はACK遅延によるsame-sequence retryをcollectorが観測したもので、128個のunique sequenceはすべて1回ずつ
集計された。重複したapplication commandの副作用を一般にexactly-onceにする保証ではない。

## トランザクション、キュー、メモリーの測定

| Phase / role | success / failure | queue bytes / chunks | max queue bytes / chunks | free heap | minimum |
| --- | ---: | ---: | ---: | ---: | ---: |
| complete / Drive | 829 / 0 | 0 / 0 | 197 / 3 | 82,380 | 73,796 |
| complete / Sensors | 810 / 20 | 135 / 2 | 369 / 6 | 80,692 | 73,796 |
| settled / Drive | 896 / 0 | 0 / 0 | 197 / 3 | 82,380 | 73,796 |
| settled / Sensors | 877 / 20 | 0 / 0 | 369 / 6 | 82,200 | 73,796 |

Sensorsの20 failureはbranch切断中の約2秒transaction timeoutに対応する。Driveは同じ期間を含めてfailure 0だった。完了時に残った
Sensorsの135 bytes / 2 chunksは30秒後に0となり、両roleともoutstanding 0へ戻った。

readiness traceのboot内high-waterはDrive 21,089 ms、Sensors 11,802 msだった。Sensorsの障害検出gap 38,388 msは旧connectionを
終了させたtimeout eventであり、replacement connectionの初回ACKを除外する通常gap high-waterには加算しない。

## クリーンブートからの反復試験

3台を通常firmwareへ戻した後、同じ診断設定を再flashしてclean bootから反復した。run `2847232948`ではSensors producerの
sequence 62まで進んだ時点でbranchを外した。SensorsはACK欠落36,943 msで旧connection `3973391217`を停止し、
connection `2567952854`、carrier session `3094562753`へ更新した。Driveは同じconnectionを維持した。

branch復帰後は複数のhandshake timeout、`unexpected`、`unsupported_name`、`no_link_manager_response`を経てSensorsが再接続し、
Sensors / Drive両probeが成功した。producerは同じsequence 62から再開した。

| Metric | 1回目 | 2回目 |
| --- | ---: | ---: |
| Sensors ACK timeout gap | 38,388 ms | 36,943 ms |
| run elapsed | 451,811 ms | 568,227 ms |
| Drive / Sensors received | 128 / 128 | 128 / 128 |
| Drive / Sensors duplicate | 3 / 0 | 11 / 0 |
| Drive / Sensors transaction failure | 0 / 20 | 1 / 62 |
| Drive / Sensors max interarrival | 21,366 / 72,741 ms | 34,671 / 182,873 ms |
| Drive / Sensors ACK gap high-water | 21,089 / 11,802 ms | 23,610 / 13,790 ms |
| Controller minimum free heap | 73,796 bytes | 72,552 bytes |

2回目もmissing、out-of-order、invalidは両roleとも0、delivery ratio gapは0‰だった。active overlapは523,934 ms、completion skewは
40,575 msだった。切断保持とhandshake retryが長く、600秒のcollector期限に対する余裕は31,773 msまで縮んだ。600秒を一般的な
安全値とはせず、operator操作を含む試験ではより長い期限を使う。

2回目の完了時queueはDrive 117 bytes / 2 outstanding、Sensors 137 bytes / 2 outstandingだった。30秒snapshotではSensorsが0 / 0へ
drainした一方、Driveは117 bytes / 2 outstandingだった。10秒周期のreadiness trafficも同じqueueを使うため、この1 snapshotだけで
未drainのtraffic dataか通常heartbeatのin-flightかは区別できない。「30秒後に常に両queueが0」とは一般化しない。

## 通常構成への復元確認

各run後に3 roleをtraffic、remote health、trace、fault無効の通常構成でcompatibility check、PackBEAM build、flashした。

| Role | `main.avm` size |
| --- | ---: |
| Sensors | 264,320 bytes |
| Drive | 264,348 bytes |
| Controller | 267,924 bytes |

両distribution connectionとprobeが成功した後、fresh stateの3-step missionは`forward 100`、`forward 100`、`right 90°`を実行し、
final statusは`{x_mm: 200, y_mm: 0, heading_deg: 90}`だった。

## 結論

round-robin scheduler、remote health restart、application ACK retryを組み合わせると、flow-controlled concurrent traffic中に
Sensors branchを物理切断してもDrive connectionを維持し、Sensors再接続後に同じproducerを再開して128+128 messagesを
2回のclean-boot runで完了できた。

restart budgetはboot中に補充されず、collector期限も障害中に停止しない。2 run間でもduplicate、transaction failure、interarrival、
完了時間に幅があった。複数回の切断、数時間のmemory stability、一般的なtermination / bias条件に対する保証はしない。
