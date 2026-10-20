# ACK timeout による remote distribution restart — 2026-10-20

## 目的

前回のresponse blackoutで残ったSensors側のstale distribution connectionを、application ACK timeoutを契機にremote自身が明示的に
teardownする。新しいconnectionを確立した後、停止させずに残したproducerが同じrun ID / sequenceから再開できるか確認する。

## 実装

- producerは各messageの最初のACK timeoutをlocal lifecycle ownerへ通知する
- opt-in設定を有効にしたremoteは`net_kernel.stop/0`の後、同じnode identity、UART設定、cookieで`net_kernel`を再開する
- Drive / Sensors application processとproducerはdistribution restartをまたいで生存する
- readiness messageにboard boot IDとは別のdistribution connection IDを追加する
- Controllerは新connection IDをreconnectとして扱い、対象roleと稼働中peerのprobeを実行する

`ROBOT_MULTINODE_RESTART_ON_TRAFFIC_ACK_TIMEOUT`のdefaultは`false`である。AVModbus core、FC-100 wire protocol、AtomVM runtimeは
変更していない。hostではtimeout通知が同じmessageで1回だけ送られることと、同一bootでconnection IDが変わればnew readinessに
分類されることを含む54 testが成功した。

## 実機条件

- 3 × Seeed Studio XIAO ESP32-C5
- shared two-wire RS485、115,200 baud
- FC-100 chunk payload 96 bytes、poll interval 20 ms
- AtomVM v0.7.0-beta.0 と既存multi-connection local patch
- 16 messages / role、64-byte payload、producer interval 500 ms
- ACK timeout 10,000 ms、retry 12、in-flight window 1
- collector timeout 300,000 ms、settle 30,000 ms
- Sensors: 60秒後から180 FC-100 responseを破棄し、ACK timeout restartを有効化

試験firmwareはDrive 250,496 bytes、Sensors 251,096 bytes、Controller 255,892 bytesだった。traffic run IDは`11157342`である。

## Recovery timeline

| 時刻 | 観測 |
| --- | --- |
| 20:31:33.036 | Controllerが16+16 traffic runを開始 |
| 20:31:40.781 | Sensorsがresponse破棄を開始 |
| 20:31:49.754 | Sensors producerがsequence 2の最初のACK timeoutを検出 |
| 20:31:49.760 | Sensors lifecycle ownerが`net_kernel` restartを開始 |
| 20:31:49.913 | 新しいServer adapterをsession `4265548736`でopen |
| 20:31:49.945 | Sensors distributionをconnection `3608876382`で再開 |
| 20:31:51.995 | Controllerがpeer session changeを検出し、古いreaderをclose |
| 20:31:55.546 | ControllerがSensorsのnew readinessをreconnectとして受信 |
| 20:31:56.322 | SensorsがController ACKを受信 |
| 20:31:59.758 | producerが同じsequence 2をretry |
| 20:32:01.659 | SensorsとDriveのrecovery probeが両方成功 |
| 20:32:36.224 | 16+16 traffic runがcomplete |

remoteの`net_kernel.stop/0`に伴い、Sensors consoleにはblocking read中の`serial_dist_controller` crash reportが表示された。
Controllerでもpeer session changeにより古いreaderの`{serial_read_error, closed}`が表示された。どちらも新handshakeを阻害しなかった。

## Application result

| Metric | Drive | Sensors |
| --- | ---: | ---: |
| expected / received | 16 / 16 | 16 / 16 |
| missing / duplicates | 0 / 0 | 0 / 0 |
| out-of-order / invalid | 0 / 0 | 0 / 0 |
| duration | 40,337 ms | 59,776 ms |
| sample span | 36,595 ms | 56,049 ms |
| throughput | 396 milli-msg/s | 267 milli-msg/s |
| max interarrival | 3,951 ms | 22,460 ms |

run elapsedは63,171 ms、active overlapは40,337 ms、completion skewは19,231 ms、delivery ratio gapは0‰だった。
Sensorsの長いmax interarrivalにblackoutとreconnectが表れている。

完了直後のController adapterは、Driveが158 success / 0 failure、Sensorsが132 success / 27 failureだった。queue high-waterは
Drive 383 bytes / 6 chunks、Sensors 391 bytes / 7 chunksだった。free heapのminimum watermarkは79,352 bytesだった。

## 診断設定の再 arm

restartでSensors adapterを作り直したため、response faultのremaining countと60秒delayも初期値へ戻った。20:32:50.186に2回目の
blackoutが始まったが、traffic runはその約14秒前に完了していた。settled snapshot時のSensors queue 10 bytes / 1 chunkと77 failuresは
この2回目のblackout中の値であり、通常時のdrain結果として扱わない。原因を確認してrunを終了した。

## 結論

remote側のdistributionを明示的に再起動すれば、非対称half-open connectionを解消し、同じproducer processが未確認sequenceを
再送できることを実機確認した。ControllerのDrive connectionは維持され、recovery probeにも成功した。

これはconcurrent traffic probe固有のopt-in recoveryである。ACK timeoutを一般的なconnection failure detectorとはみなさず、
複数distribution connectionを持つremoteへ`net_kernel.stop/0`をそのまま適用しない。今後はapplication trafficに依存しないremote health、
restart failureのbounded policy、物理的な抜き差しに対する挙動を分けて調べる。

## 通常構成への復帰確認

試験後、fault、traffic、ACK-timeout restartを無効にし、Drive 250,496 bytes、Sensors 250,464 bytes、Controller 255,180 bytesの
通常firmwareをbuildしてflashした。両distribution link、Drive / Sensors probe、3-step sensor-driven missionが成功し、最終stateは
`%RobotSim.Rover{x_mm: 200, y_mm: 0, heading_deg: 90}`だった。
