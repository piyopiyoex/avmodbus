# 0010: concurrent producer を application ACK で制限する

- Status: accepted
- Date: 2026-10-20

## 背景

Drive と Sensors が500 ms間隔で64 messagesずつ送る試験では、applicationの生成速度がshared RS485 busの排出速度を上回った。
Sensors側FC-100 outgoing queueが上限に達し、carrierは`:queue_full`でfail fastしてsessionを切り替えた。distributionは再接続したが、
元のproducer workloadは完了しなかった。

carrier queueを増やす、producer間隔を固定値で長くする、applicationでflow controlする、のいずれかを選ぶ必要がある。

## 判断

- concurrent traffic probeのstarted、sample、finished messageにproducer PIDを含める
- Controller collectorは受信した各messageへapplication ACKを返す
- 各remote producerのin-flight windowを1にし、ACK受信後だけ次のsampleへ進む
- producer intervalはACK受信後の最小待ち時間として扱う
- ACK timeout時は同じrun ID、role、sequenceを限定回数retryする
- collectorは既存のsequence trackingでretryによるduplicateを検出し、二重deliveryとして数えない
- carrier queue上限、FC-100 wire protocol、AVModbus coreは変更しない

## 影響

- producer rateはbusの実効throughputに追従し、application burstによるremote queue飽和を防げる。
- 2 roleは独立producerのままだが、それぞれ最大1 messageだけを未確認状態にする。
- messageごとに逆方向ACKが必要なため、flow controlなしの場合よりthroughputは低下する。
- application ACKはdurable deliveryやexactly-onceを意味しない。collector crash、node reboot、ACK retry上限超過ではworkloadが停止し得る。
- connection interruption中のproducer resumeとduplicate behaviorは別のfault-injection試験で検証する。
