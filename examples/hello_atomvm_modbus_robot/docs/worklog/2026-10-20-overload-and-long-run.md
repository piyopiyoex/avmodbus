# Concurrent traffic overload と longer run — 2026-10-20

## 目的

baseline / moderate より高い同時負荷で、application delivery、Unit別 transaction fairness、queue high-water、Controller heapを測定する。
続いて64 messages / role の longer runを実施し、短時間 profileを越えた安定性と failure recovery の境界を確認する。

## Metrics の追加

`DisterlProbe.ModbusUART` に観測専用の metrics snapshot/resetを追加した。snapshotは次をUnit IDごとに返す。

- transaction polls、successes、failures、average / maximum elapsed time
- 現在の queued bytes / outstanding chunks
- 測定window内の queued bytes / outstanding chunks high-water
- ESP32 free heap、largest free block、minimum free heap watermark

reset時に進行中 transaction がある場合は active requestを保持し、完了callbackを壊さない。transaction / queue traceにもUnit IDを追加した。
Robot Controller はtraffic開始直前にmetricsをresetし、開始前、完了直後、default 30秒後にsnapshotを出力する。
AVModbus core、FC-100 packet、distribution protocolは変更していない。

Host testはDisterl 62件、Robot 52件で成功し、ControllerのAtomVM compatibility checkにも成功した。

## 共通環境

- 3 × Seeed Studio XIAO ESP32-C5
- shared two-wire RS485、115,200 baud
- FC-100 chunk payload 96 bytes、poll interval 20 ms
- AtomVM v0.7.0-beta.0 と既存 multi-connection local patch
- Drive Unit 1、Sensors Unit 2

## Exploratory overload

設定は両 role 250 ms、各20 messages、64-byte payload、180秒timeoutである。Controllerはtransaction / queue traceを有効にした。

application result:

| Metric | Drive | Sensors |
| --- | ---: | ---: |
| expected / received | 20 / 20 | 20 / 20 |
| missing / duplicates | 0 / 0 | 0 / 0 |
| out-of-order / invalid | 0 / 0 | 0 / 0 |
| duration | 24,889 ms | 26,665 ms |
| throughput | 803 milli-msg/s | 750 milli-msg/s |
| max interarrival | 1,230 ms | 1,265 ms |

run elapsedは29,769 ms、active overlapは23,579 ms、completion skewは1,310 ms、delivery ratio gapは0‰だった。

carrier metrics:

| Metric | Unit 1 / Drive | Unit 2 / Sensors |
| --- | ---: | ---: |
| success / failure | 69 / 1 | 70 / 0 |
| average elapsed | 382 ms | 383 ms |
| maximum elapsed | 2,002 ms | 1,996 ms |
| queue high-water | 261 bytes / 4 chunks | 149 bytes / 2 chunks |

Driveの1 transactionが2秒timeoutになったが、FC-100 retransmissionとduplicate suppressionによりapplication messageは20件すべて届いた。
両Unitのpoll数は70対71で、短時間の範囲ではshared Clientによる一方的なstarvationは観測しなかった。queue上限8,192 bytes /
256 chunksには十分な余裕があった。

開始前のfree heapは約89 KB、minimum watermarkは85,868 bytesだった。完了直後はfree heapがDrive snapshotで86,360 bytes、
Sensors snapshotで85,436 bytes、minimum watermarkは80,292 bytesだった。このrunはsettled snapshot追加前のため、回復後の値は取得していない。

## 64 messages / role longer run

設定は両 role 500 ms、各64 messages、64-byte payload、300秒timeout、trace無効、30秒settled snapshot有効である。
producerが全messageを生成する理論時間は31.5秒だが、shared half-duplex bus上のdeliveryはそれより長くなる。

23–24 messages受信後、外部reset操作なしで両FC-100 peer session IDが変化した。古い`serial_dist_controller` readerは
`{serial_read_error, closed}`で終了した。その後distribution connectionとreadiness heartbeatは回復したが、session change前に起動した
producer processは再開されず、collectorは300秒でtimeoutした。

| Metric | Drive | Sensors |
| --- | ---: | ---: |
| expected / received | 64 / 23 | 64 / 24 |
| missing / duplicates | 41 / 0 | 40 / 0 |
| out-of-order / invalid | 0 / 0 | 1 / 0 |
| max interarrival | 3,260 ms | 5,489 ms |
| finished | false | false |

session再接続後もcarrier pollingは継続した。300秒時点のmetricsは次のとおりである。

| Metric | Unit 1 / Drive | Unit 2 / Sensors |
| --- | ---: | ---: |
| success / failure / active | 832 / 1 / 1 | 831 / 2 / 1 |
| average elapsed | 325 ms | 326 ms |
| maximum elapsed | 2,003 ms | 2,011 ms |
| queue high-water | 378 bytes / 6 chunks | 290 bytes / 4 chunks |

queueは完了直後と30秒後の両方で0だった。heapは次のように推移した。

| Phase | Free heap (Drive snapshot) | Free heap (Sensors snapshot) | Minimum watermark | Largest block |
| --- | ---: | ---: | ---: | ---: |
| before | 89,708 bytes | 89,176 bytes | 86,384 bytes | 69,632–73,728 bytes |
| after timeout | 85,788 bytes | 85,384 bytes | 80,736 bytes | 65,536 bytes |
| settled 30 s | 86,224 bytes | 85,672 bytes | 80,736 bytes | 65,536 bytes |

free heapはsettled snapshotで一部回復し、queue残留はなかった。ただし開始前より約3.5 KB低く、1 runだけではleakかconnection再確立後の
常駐allocationかを区別できない。minimum watermarkは履歴値なので回復しない。

ここで記録したqueueはController上のUnit別client adapterである。Drive / Sensors上のserver adapterが持つoutgoing queueは、このsnapshotに
含まれない。

## 3台同時consoleによる原因特定

同じ64+64、500 ms、64-byte profileを再buildし、Drive、Sensors、Controllerのconsoleをtimestamp付きで同時取得した。この診断runは
直接原因と再接続を確認した時点で手動終了し、300秒collector timeoutまでは継続していない。

Sensors側では次の順に発生した。

1. traffic開始から約32.5秒後、199-byte distribution writeが`:queue_full`で拒否された。
2. `ModbusUART`がfail-fast policyに従いsessionを`757192946`から`574814549`へ切り替えた。
3. Sensors側`serial_dist_controller`が`{serial_write_error, queue_full}`で終了した。
4. 約250 ms後、Controllerがpeer session changeを検出し、readerが`{serial_read_error, closed}`で終了した。
5. ControllerはSensors readiness lease expiryを記録後、queue-fullから約31.9秒でdistributionを再接続し、約51.7秒でrecovery probeを
   完了した。

外部reset、watchdog、heap exhaustionは先行していない。producerは500 msごとにmessageを生成した一方、shared half-duplex busは同じ速度で
2 streamを排出できず、Sensors側outgoing queueがbounded limitに達したことがsession resetの直接原因である。Drive側では診断runを
終了するまでqueue-fullを観測しなかった。

この結果はbounded queueとfail-fast recoveryが意図通りmemoryを保護したことも示す。一方、distributionの`send`はapplication producerへ
carrier congestionをbackpressureとして返さない。application ACK、bounded in-flight window、または明示的なproducer resumeが必要である。

## 結論

20 messages / role のoverloadは1回のphysical transaction timeoutをFC-100層で吸収し、application deliveryを完了した。一方、
64 messages / role のrunではcarrier session reset後にapplication producerが失われ、transport reconnectだけではworkloadを完了できなかった。

次はrun IDとroleに対するapplication ACK、bounded in-flight window、producer再開、重複抑止、期限を設計し、同じ64+64 profileを
再試験する。4台目への拡張はflow control付きlonger runを評価するまで保留する。

## 通常構成への復帰確認

実験後、Controllerをtraffic無効の通常構成で再buildした。`atomvm.check`と`atomvm.packbeam`は成功し、firmware sizeは
252,844 bytesだった。Controllerへflash後に3台を再起動し、Drive / Sensorsの両distribution link、remote probe、3-step
sensor-driven missionを再確認した。

最終状態は`%RobotSim.Rover{x_mm: 200, y_mm: 0, heading_deg: 90}`で、`complete Drive and Sensors remote messaging`まで
正常に到達した。その後の3台同時console診断のため64-message profileを一時的に再flashしたが、診断終了後に詳細なqueue-full logを
含む通常構成（253,432 bytes）へ再度戻した。3台をclean rebootし、同じ最終状態と完了logを再確認した。
