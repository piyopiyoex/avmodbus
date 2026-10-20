# Application ACK flow control 実機検証 — 2026-10-20

## 目的

flow controlなしの64 messages / role試験で発生したremote outgoing queueの`:queue_full`を、carrier queue拡大ではなく
application-level flow controlで防ぐ。同じ3台、payload、producer interval、chunk設定を使い、64+64 messagesを完了できるか確認する。

## 実装

Drive / Sensorsの各producerをstop-and-wait方式にした。

- started、各sample、finishedにproducer PIDを付加する
- Controller collectorは各messageへACKを返す
- roleごとのin-flight windowは1
- ACK受信後にproducer intervalを待ち、次のsampleを送る
- ACK timeout時は同じrun IDとsequenceをretryする
- default ACK timeoutは90秒、retryは1回

host testでは初回sample ACKを意図的に破棄し、同じsequenceがretryされることを確認した。Robot testは53件成功し、
Controllerの`atomvm.check`も成功した。設計判断は[ADR 0010](../adr/0010-bound-concurrent-producers-with-application-acks.md)に記録した。

## 実機条件

- 3 × Seeed Studio XIAO ESP32-C5
- shared two-wire RS485、115,200 baud
- FC-100 chunk payload 96 bytes、poll interval 20 ms
- AtomVM v0.7.0-beta.0 と既存multi-connection local patch
- Drive / Sensors interval: 500 ms
- 64 messages / role、64-byte application payload
- in-flight window: 1 / role
- ACK timeout: 90,000 ms、retry: 1
- collector timeout: 600,000 ms

firmware sizeはController 255,272 bytes、Drive 249,620 bytes、Sensors 249,588 bytesだった。

## 結果

| Metric | Drive | Sensors |
| --- | ---: | ---: |
| expected / received | 64 / 64 | 64 / 64 |
| missing / duplicates | 0 / 0 | 0 / 0 |
| out-of-order / invalid | 0 / 0 | 0 / 0 |
| duration | 159,412 ms | 158,168 ms |
| sample span | 155,842 ms | 154,438 ms |
| throughput | 401 milli-msg/s | 404 milli-msg/s |
| max interarrival | 5,424 ms | 4,425 ms |

run elapsedは163,039 ms、active overlapは156,298 ms、completion skewは3,114 ms、delivery ratio gapは0‰だった。
queue-full、session change、producer ACK timeout、application retryは観測しなかった。

Controller側carrier metrics:

| Metric | Unit 1 / Drive | Unit 2 / Sensors |
| --- | ---: | ---: |
| success / failure | 401 / 1 | 401 / 1 |
| average elapsed | 367 ms | 368 ms |
| maximum elapsed | 2,012 ms | 2,004 ms |
| queue high-water | 383 bytes / 6 chunks | 159 bytes / 2 chunks |

両linkで1回ずつphysical transaction timeoutが発生したが、application resultには影響しなかった。完了直後はDrive側Controller adapterに
131 bytes / 2 chunksが残っていたが、30秒後には両adapterとも0になった。

Controller free heapは開始前がDrive snapshot 89,624 bytes / Sensors snapshot 89,084 bytes、完了直後が85,244 / 84,660 bytes、
30秒後が85,904 / 85,356 bytesだった。minimum watermarkは79,020 bytes、settled時のlargest free blockは65,536 bytesだった。
単一runだけではmemory leakの有無を判断しない。

## 結論

window 1のapplication ACKにより、以前約32.5秒で発生したremote queue-fullを回避し、同じ64+64 workloadを完全配送できた。
bounded carrier queueを拡大する必要はなかった。一方、所要時間は約163秒であり、この方式はthroughputよりbounded memoryと回復可能性を
優先する。

次は通信断中にACK timeoutを発生させ、distribution reconnect後に同じsequenceのretryが完了するか、duplicate countとproducer期限を
含めて確認する。

## 通常構成への復帰確認

試験後、Controllerをtraffic無効の通常構成（254,764 bytes）で再buildし、`atomvm.check`、PackBEAM、flashに成功した。
3台をclean rebootし、両distribution link、remote probe、3-step sensor-driven missionを再確認した。最終状態は
`%RobotSim.Rover{x_mm: 200, y_mm: 0, heading_deg: 90}`で、試験用64-message profileはdeviceに残していない。
