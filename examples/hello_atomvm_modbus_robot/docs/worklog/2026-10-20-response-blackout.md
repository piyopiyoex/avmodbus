# Server response blackout と非対称 half-open connection — 2026-10-20

## 目的

application ACKでin-flight windowを1にしたconcurrent traffic probeの進行中に通信障害を発生させ、ACK timeout後の
same-run / same-sequence retry、distribution reconnect、producer resumeを3台の実機で確認する。

## Fault injection

既存carrierの`DisterlProbe.ResponseFault`をrobot exampleからcompile-time configurationできるようにした。

| 環境変数 | 試験値 | 意味 |
| --- | ---: | --- |
| `MODBUS_FAULT_DROP_RESPONSES` | `180` | Sensorsが受理後に破棄するFC-100 response数 |
| `MODBUS_FAULT_MIN_PAYLOAD_BYTES` | `0` | payload sizeによらずresponseを対象にする |
| `MODBUS_FAULT_AFTER_MS` | `60000` | adapter起動60秒後に破棄を開始する |

このfaultはServer responseだけを破棄する。ControllerからSensorsへのrequestはSensorsに到達するため、双方向のRS485 cable断とは
異なる非対称なfailure modelである。AVModbus coreとFC-100 wire protocolは変更していない。

## 実機条件

- 3 × Seeed Studio XIAO ESP32-C5
- shared two-wire RS485、115,200 baud
- FC-100 chunk payload 96 bytes、poll interval 20 ms
- AtomVM v0.7.0-beta.0 と既存multi-connection local patch
- Drive / Sensors interval: 500 ms
- 32 messages / role、64-byte application payload
- in-flight window: 1 / role
- ACK timeout: 10,000 ms、retry: 12
- collector timeout: 600,000 ms、settle: 30,000 ms

試験firmwareはController 255,472 bytes、fault有効Sensors 249,788 bytesだった。traffic run IDは`1189118181`である。

## 観測結果

Sensors adapterの起動時刻を基準にした60秒後、20:15:29.658にresponse破棄が始まった。Sensors producerは
`{:sample, 7}`のACKを受信できず、20:15:39.403から10秒ごとに同じrun ID / sequenceを再送した。

| 時刻 | 観測 |
| --- | --- |
| 20:15:12.368 | Controllerがtraffic runを開始 |
| 20:15:29.658 | SensorsがFC-100 responseの連続破棄を開始 |
| 20:15:39.403 | Sensorsがsequence 7のsame-sequence retryを開始 |
| 20:15:55.680 | ControllerのSensors readiness leaseがexpire |
| 20:16:31.095 | Controller側distribution connectionが`net_tick_timeout`で終了 |
| 20:16:34.876 | 180 responseの破棄が終了し、physical pollingが復帰 |
| 20:17:39.468 | Sensors producerが12回のretryを使い切り、`{:ack_timeout, {:sample, 7}}`で停止 |

response破棄終了後、ControllerではSensors streamの`delivered bytes=...`が再び継続して記録された。一方でpeer session change、
新しいdistribution handshake、application recovery logは発生しなかった。Sensorsはblackout中もControllerのrequestとtickを受信していたため、
自分の古いdistribution connectionを閉じず、30秒ごとのreadiness heartbeatとretryをそのstreamへqueueし続けた。

この状態ではphysical Modbus transportだけが復帰し、distribution connectionは両端で一致しない。Controllerの新しい接続相手が存在しないため、
same-sequence retryはController applicationへ届かなかった。原因を確認した時点で診断runを手動終了したため、600秒後のcollector summaryはない。

## 結論

ACK timeoutとsame-sequence bounded retryは意図どおり動作したが、それだけでは非対称な`net_tick_timeout`から回復できなかった。
physical pollingやcarrier byte deliveryの復帰をdistribution reconnectとみなしてはいけない。

次の実装課題は、片側のconnection lossをremoteへ通知または検出させ、stale distribution connectionを明示的にteardownした後に
両端でhandshakeを再開するlifecycleである。その上で、connectionより長く生存するownerが未確認run ID / sequenceを保持し、再接続後に
producerを再開する必要がある。application ACK retry回数だけを増やすことは解決にならない。

この課題は同日のopt-in follow-upで、remote側`net_kernel`をACK timeout時に再起動する方法を使って実証しました。結果は
[ACK timeoutによるremote distribution restart](2026-10-20-response-blackout-recovery.md)を参照してください。

## 通常構成への復帰確認

試験後、Sensorsをfault無効の通常構成（249,788 bytes）、Controllerをtraffic無効の通常構成（254,764 bytes）へ再buildしてflashした。
3台をclean rebootし、両distribution link、Drive / Sensors probe、3-step sensor-driven missionを再確認した。最終stateは
`%RobotSim.Rover{x_mm: 200, y_mm: 0, heading_deg: 90}`で、fault / traffic試験構成はdeviceに残していない。
