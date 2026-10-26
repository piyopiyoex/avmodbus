# Stage 7 長時間通信断時の現行ポリシー基準値

## 目的

Stage 7のlifecycle eventを導入した3台で、90秒のremote health timeoutより短いSensors branch切断と、timeoutを越える切断を
比較する。restart timingを変更する前のcurrent policyを基準として残す。

## 条件

- 3 × Seeed Studio XIAO ESP32-C5
- AtomVM `release-0.7` snapshot `18b35870` + local patch `a1069573`
- 115,200 baud、96-byte chunk、20 ms poll
- breadboard上のcontinuous A/B trunkとSensors専用branch
- `ROBOT_MULTINODE_CONNECTION_TRACE=true`
- `ROBOT_MULTINODE_METRICS_INTERVAL_MS=10000`
- `ROBOT_MULTINODE_REMOTE_HEALTH_ENABLED=true`
- `ROBOT_MULTINODE_REMOTE_HEALTH_TRACE=true`
- remote readiness ACK timeout 90秒、restart budget 1

USB serial IDとroleの対応は次のとおりだった。

| Role | USB serial ID | 試験開始時のdevice |
| --- | --- | --- |
| Controller | `38:44:BE:A5:05:14` | `/dev/ttyACM0` |
| Sensors | `10:BD:A3:CF:09:04` | `/dev/ttyACM1` |
| Drive | `38:44:BE:A5:04:DC` | `/dev/ttyACM2` |

Controllerだけが使っていたUSB connector adapterではROM bootloaderへの接続が繰り返し失敗した。adapterを外して別のhost portへ
直接接続すると`esptool chip-id`とflashが成功したため、今回のhardware setupではそのadapterを使わなかった。これはRS485の
failureではなく、firmware導入時のUSB経路の問題として分けて扱う。

RESETをまたぐconsole記録にはPTY付き`tio`を使った。非対話のpicocomはCDC ACM切断後に終了したため、fault試験の正式logには
自動再接続した`tio`のtimestamp付きlogを用いた。

## 障害なしの基準値

3台へinstrumented firmwareを導入し、adaptive mission完了、両peerの継続poll、queueの0へのdrainを確認した。
Sensorsを単独RESETした試験では、Controllerが新しいFC-100 sessionを検出し、Sensors再起動から約4秒で
`remote_reconnected`、約9秒で`recovery_verified`を記録した。Driveは同じconnection IDを維持した。

その後、faultを入れず翌朝までidle connectionを継続した。Sensorsの`minimum_free_heap_bytes`は84,648 bytes、Driveは
81,136 bytesで、periodic free heapはSensors約90–92 KiB、Drive約87–88 KiBを維持した。これは約10時間のidle baselineであり、
application trafficを継続したsoakではない。

## Scenario 1: Health timeoutを越える切断

Sensors clean bootでrestart budgetを未使用の状態からbranchを外した。利用者応答を記録した時刻は次のとおりである。

| 操作 | 記録時刻 |
| --- | --- |
| removed応答 | 2026-10-25 23:08:04 JST |
| restored応答 | 2026-10-25 23:09:41 JST |

応答間隔は約97秒だが、取り外しと復元の厳密な電気的時刻ではない。観測順序は次のとおりだった。

1. Controllerは23:08:38にSensors connectionを`net_tick_timeout`で閉じ、23:08:42に`stale_detected`を記録した。
2. Drive transaction failureは2のままで、Drive connectionを維持した。
3. SensorsはACK gap 118,168 msで23:09:25にrestartを開始した。
4. `restart_started`時のSensors free heapは91,396 bytes、largest free blockは73,728 bytes、minimum watermarkは
   84,520 bytesだった。
5. `kernel_stop_requested`の約3秒後、`:net_kernel`が`<0.5.0>`のまま残り、`kernel_stop_failed`と
   `restart_failed`を`net_kernel_stop_timeout`で記録した。
6. `kernel_stop_completed`、`kernel_start_started`、`kernel_start_succeeded`には到達しなかった。
7. remote processは明示的にhaltし、branch復元後もSensors pollingは自動復旧しなかった。

以前の約199秒試験で観測した14,428 bytesまでのminimum free heap低下は、このscenarioでは再現しなかった。今回のfailureは
memory低下より前のkernel stop完了待機で発生した。

Sensorsを単独RESETすると、Controllerは23:10:58の新FC-100 sessionを検出し、23:11:02に`remote_reconnected`、
23:11:07に`recovery_verified`と`peer_maintained role=drive`を記録した。ControllerとDriveのRESETは不要だった。

## Scenario 2: Health timeout未満の切断

Scenario 1後にSensorsをRESETし、restart budgetを初期化した。同じconnection ID `91316922`で安定した後、Sensors branchを短時間
外した。利用者応答の記録は09:31:09から09:31:51までの42秒だが、branchは復元してから`restored`応答が届いているため、
厳密な電気的切断時間ではない。

| 指標 | 結果 |
| --- | ---: |
| Sensors readiness ACK gap | 67,389 ms |
| Sensors connection ID | `91316922`のまま |
| restart / kernel lifecycle event | 0 |
| Sensors transaction failure増分 | 19 |
| fault中のglobal queue観測最大 | 30 bytes / 3 chunks |
| 復帰後のglobal queue | 0 bytes / 0 chunks |
| Sensors minimum free heap watermark | 84,648 bytes |
| Drive connection ID | `2209988514`のまま |

Sensorsは09:31:37に同じconnection IDでACKを再開し、次のACK gapは988 msだった。global queueは09:31:42までにdrainした。
Sensors periodic free heapはfault前後とも約91–92 KiBで、restart budgetを消費しなかった。Driveも同じconnectionを維持した。

## 判断

- health timeout未満の切断は、同じdistribution connectionとFC-100 sessionで復帰できた。
- health timeoutを越えたscenarioでは、physical branch復元前にrestartを開始し、`net_kernel` stop完了待機で失敗した。
- 今回のevent分解により、`restart_succeeded`より前のkernel stop段階をfailure位置として特定できた。
- 約199秒scenarioのheap低下と、今回の`net_kernel_stop_timeout`は同一原因と断定できない。
- restart回数やtimeoutを増やす根拠は得られていない。

この結果を基準に、physical transportが復帰するまでrestartを保留する条件を設計した。単発poll成功だけをreadinessとせず、
FC-100 sessionと連続transaction成功を用いたboundedな条件をhostで先に検証した。比較結果は
[transport復帰後のrestart保留](2026-10-26-stage-7-deferred-restart.md)に記録した。
