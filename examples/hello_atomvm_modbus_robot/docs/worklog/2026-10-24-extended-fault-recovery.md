# Sensors branchの短時間切断と長時間復旧

## 目的

3台のconcurrent traffic中にSensors branchだけを切断し、正常なDriveの継続、Sensors復帰、message欠損、restart eventを確認する。
最初に操作時間が延びたcalibration runを行い、その後に手元で30秒を計る短時間runをclean bootから実行した。

## 共通条件

- 3 × Seeed Studio XIAO ESP32-C5
- AtomVM `release-0.7` snapshot `18b35870` + local patch `a1069573`
- 115,200 baud、96-byte chunk、20 ms poll、breadboard hub配線
- Controller: Drive / Sensors各64 messages、64-byte payload、application ACK window 1
- traffic timeout 600秒、application ACK timeout 240秒、retry 1
- remote readiness ACK timeout 90秒、restart budget 1
- 3 roleで10秒periodic metricsとconnection traceを有効化

## Calibration: 約1分超の切断

最初の操作では、切断指示、30秒待機、復元指示、利用者の復元操作を直列に行ったため、実際の切断が予定より長くなった。
このrunは30秒scenarioの結果には数えず、長めの切断で生じたblockerとして保存した。

観測した順序は次のとおりである。

1. Sensors transaction failureが増加し、Driveはfailure 0でpollとapplication trafficを継続した。
2. ControllerがSensors readiness lease expiryを検出した。
3. Controller側distributionが`net_tick_timeout`でSensors connectionを閉じた。
4. branch復元直後はUnit 2のphysical pollingが一時的に再開した。
5. Sensorsはreadiness ACK gap 117,973 msでremote-side restartを開始した。
6. `net_kernel.stop`が3秒以内に完了せず、`{:net_kernel_stop_timeout, pid}`でrestartに失敗した。
7. restart失敗後はSensors adapterが応答せず、Unit 2 transaction failureが増え続けた。Driveはfailure 0を維持した。

これはboard resetなしに復旧しない具体的なruntime blockerである。remote-side recoveryがdistribution停止だけでなくFC-100 adapterの
lifecycleにも影響し、失敗後にphysical Modbus応答まで失われる。AtomVM upstreamへのIssue / PRはこのexampleの対象にせず、
現在のv0.7 snapshotに対する制約として記録する。

## 手元計測30秒run

3台をclean bootし、両remote接続、probe、sensor-driven mission、64+64 traffic開始を確認してから、利用者がSensors branchを外し、
手元で30秒後にControllerからの追加指示を待たず復元した。

Controllerが観測した連続timeoutからphysical応答再開までの区間は約37秒だった。poll interval、進行中transaction、手動操作を含むため、
これは電気的切断時間そのものの精密測定ではない。Sensors readiness ACK gap high-waterは65,357 msで、75秒leaseと90秒remote health
timeoutには達しなかった。

### 結果

| 指標 | 結果 |
| --- | ---: |
| Traffic outcome | complete |
| Drive delivery | 64 / 64 |
| Sensors delivery | 64 / 64 |
| Missing / duplicates / invalid | 0 / 0 / 0 |
| Elapsed | 307,034 ms |
| Drive / Sensors max interarrival | 11,601 / 39,484 ms |
| Drive / Sensors transaction failure | 0 / 17 |
| Restart / reconnect event | 0 / 0 |
| Global queue high-water | 900 bytes / 14 chunks |
| Global rejection | 0 |
| Controller minimum free heap | 63,224 bytes |
| Drive minimum free heap | 77,440 bytes |
| Sensors minimum free heap | 80,928 bytes |

同じdistribution connectionでapplication trafficが再開し、両roleとも欠損・重複なしで完了した。settled metricsではglobal queueが
0 bytes / 0 chunksへ戻った。保存した3 role logを`RobotSim.EnduranceReport`で集計し、malformed 0、`successful: true`を確認した。

## 判断

- 75秒leaseより短い今回の短時間切断は、restartなしで同じconnectionを維持して完全配送した。
- 正常なDriveは両runでtransaction failure 0を維持した。
- 操作時間がlease / tick境界を超えると、physical bus復元だけではapplication connectionが戻らない。
- calibrationで見つかった`net_kernel_stop_timeout`後のadapter停止は、条件により再現しないことがあるため、
  connection eventとphysical responseを合わせて判定する。
- 30秒の成功から、任意の短時間切断や90秒以上の自動復旧を保証しない。

## 約90秒を狙ったidle接続中の切断

同じfirmwareを3台へclean bootし、64+64 trafficが完了した後のidle接続中にSensors branchを外した。利用者操作と
serial logの間に共通の外部時計を置かなかったため、電気的な切断時間を正確に90秒とは断定しない。ControllerがUnit 2の
最初のtimeoutを記録してから`remote_reconnected`までの区間は約116秒、Sensorsが最後のreadiness ACKからrestart判断までに
記録したgapは118,097 msだった。

観測した順序は次のとおりである。

1. ControllerでUnit 2のtransaction failureが増えた。Unit 1はpollを継続した。
2. Controller側のSensors connectionが`net_tick_timeout`で閉じ、75秒のreadiness lease expiryにより
   `stale_detected`を記録した。
3. Sensorsは90秒のACK timeoutを超えて`restart_started`を記録した。
4. 今回は`net_kernel.stop`がtimeoutせず、約0.2秒で`restart_succeeded`となった。
5. branch復元後、新しいconnection IDで`remote_reconnected`、`readiness_acknowledged`、probe成功を確認した。
6. ControllerはSensorsの`recovery_verified`と、同じconnection IDを維持したDriveの`peer_maintained`を記録した。

| 指標 | 結果 |
| --- | ---: |
| Fault時のtraffic | idle（64+64 traffic完了後） |
| Sensors ACK gap at restart | 118,097 ms |
| Restart | 1 started / 1 succeeded / 0 failed |
| Reconnect / recovery verified | 1 / 1 |
| Drive connection | 維持 |
| Fault前後のDrive transaction failure | 1 → 1 |
| Fault前後のSensors transaction failure | 2 → 45 |
| Global queue rejection | 0 |
| Controller minimum free heap | 63,428 bytes |
| Drive minimum free heap | 77,404 bytes |
| Sensors minimum free heap | 81,196 bytes |

`RobotSim.EnduranceReport`でmalformed 0、restart started / succeeded 1、remote reconnect 1、`successful: true`を確認した。
この成功はidle connectionの自律復旧を示す。この時点では通信中の90秒切断におけるapplication messageの欠損・重複は未検証であり、
30秒runの結果と混同しない。

Calibration runではrestartが`net_kernel_stop_timeout`で失敗し、今回のidle runでは同じtimeout境界を越えて成功した。
この差から、切断時間だけではrestart成否を決められず、切断時のdistribution / adapter状態も影響すると考えられる。
これは観測に基づく推測であり、AtomVM runtime内部の原因は確定していない。

## 同一bootでの長時間切断反復

上のidle run後にSensorsをresetせず、Controllerだけを連続traffic用firmwareへ更新した。したがってSensorsの
`ROBOT_MULTINODE_REMOTE_MAX_RESTARTS=1`は消費済みである。この状態で256+256 traffic中にSensors branchを約90秒外し、
同一bootで長時間切断を反復した場合のrestart budgetを確認した。

Controllerのprofileは3 runs、256 messages / role、64-byte payload、240秒application ACK timeout、retry 1だった。
ただし900秒のrun timeoutは過去の256-message実測速度に対して余裕が不足する。このrunはtraffic完了率の測定には使わず、
明示的なproducer failureまでで終了した。

観測した順序は次のとおりである。

1. traffic開始後、Sensorsの最初のphysical timeoutを記録した。Driveはtransaction failure 0で送信を継続した。
2. Controller側Sensors connectionは`net_tick_timeout`で閉じ、`stale_detected`を記録した。
3. branch復元後にUnit 2 pollingは再開し、Sensors transaction failureは43で増加が止まった。
4. Sensorsはremote health timeout時にrestart budget消費済みを検出し、`restart_budget_exhausted`を記録した。
5. Sensors distributionは再接続せず、producerは`sample 9`のACKを240秒待って同一sequenceを1回再送した。
6. さらに240秒後、producerは`{:ack_timeout, {:sample, 9}}`で停止した。

| 指標 | 結果 |
| --- | ---: |
| Fault時のtraffic | active、run 1 / 3 |
| Sensors restart budget | exhausted、再接続なし |
| Sensors producer | sample 9でretry 1後に停止 |
| Drive transaction failure | 0 |
| Sensors transaction failure | 43で停止 |
| Global queue high-water | 400 bytes / 8 chunks |
| Global rejection | 0 |
| Controller minimum free heap | 64,464 bytes |
| Drive minimum free heap | 77,096 bytes |
| Sensors minimum free heap | 80,944 bytes |

collectorのrun timeoutまでは待たず、producerの明示的停止後に3 role logを閉じた。このためmissing / duplicatesの最終summaryは
得ておらず、application outcomeはcompleteではない。`RobotSim.EnduranceReport`は`stale_detected: 1`、
`restart_budget_exhausted: 1`、traffic complete 0、`successful: false`と集計した。

この結果は、restart budgetが同一boot内の複数障害に対する共有上限であり、物理Modbus応答が戻ってもdistributionと
進行中application trafficは自動復旧しないことを示す。この時点では、独立したclean bootでの通信中90秒切断は未検証だった。

## Clean bootでの通信中約90秒切断

3台をresetしてrestart budgetを初期化し、Drive / Sensors各64 messagesを3 runs、run間idleなしで開始した。run 1の
通信中にSensors branchを外し、手元で約90秒後に復元した。操作時刻はserial logと共通の外部時計で記録していないため、
正確な電気的切断時間ではなく「約90秒を狙った試験」とする。

観測した順序は次のとおりである。

1. 21:47:55にControllerがUnit 2の最初のpoll timeoutを記録した。Drive側のpollとapplication deliveryは継続した。
2. Controllerは`stale_detected`と`net_tick_timeout`を記録した。Sensorsはreadiness ACK gap 118,191 msで
   `restart_started`となり、約0.2秒後に`restart_succeeded`を記録した。
3. 新しいconnectionの8秒readiness待機中にはphysical streamが安定せず、`initial_connection_timeout`に続いて
   `restart_budget_exhausted`となった。Controllerが新しいFC-100 sessionを認識したのはその約1.5秒後だった。
4. run 1はDrive 64 / 64、Sensors 38 / 64で600秒timeoutとなった。欠損はSensors 26、重複と順序違反は両roleとも0だった。
5. Sensorsでは失敗したhandshakeの送信が滞留し、8,156 bytes / 95 chunksでpeer queue上限に達した。
   queue-full処理がstream sessionをresetし、Controllerは新しいsessionを認識した。
6. 最初のphysical timeoutから約481秒後、FC-100 session復帰から約383秒後に`remote_reconnected`を記録した。
   続いてSensorsの`recovery_verified`とDriveの`peer_maintained`を確認した。
7. run 2は再接続待ちのため開始時刻に約240秒の偏りが出たが、最終的に両role 64 / 64を欠損・重複なしで完了した。

| 指標 | run 1 | run 2 |
| --- | ---: | ---: |
| Outcome | timeout | complete |
| Drive delivery | 64 / 64 | 64 / 64 |
| Sensors delivery | 38 / 64 | 64 / 64 |
| Missing / duplicates / invalid | 26 / 0 / 0 | 0 / 0 / 0 |
| Elapsed | 600,000 ms | 459,975 ms |
| Drive duration | 350,316 ms | 276,463 ms |
| Sensors duration | 未完了 | 216,601 ms |
| Drive / Sensors transaction failure | 1 / 45 | 0 / 2 |

全観測期間のglobal queue high-waterは779 bytes / 12 chunks、global rejectionは0だった。minimum free heapはController
63,668 bytes、Drive 77,096 bytes、Sensors 60,624 bytesだった。Sensorsは失敗したhandshake中にfree heapが一時的に
低下したが、queue-full reset後は約84 KiBへ戻った。この単発試験だけからmemory leakの有無は判断しない。

3 runs目の途中でlogを閉じたため、endurance campaign全体は未完了である。集計結果はtraffic timeout 1 / complete 1、
restart started / succeeded 1、restart budget exhausted 1、remote reconnect 1、`successful: false`となった。Sensors logの
起動直後にconsole出力が1行混線し、`malformed_lines: 1`も記録した。これはfault中のprotocol破損ではないが、raw logの
欠損として除外しない。

この結果から、clean bootでも通信中の約90秒切断では進行中runの完全配送を保証できない。一方、正常なDrive connectionを
維持し、全boardの手動resetなしでSensors connectionと後続runを復旧できた。復旧は約6分以上遅延しており、現在の
remote restartはphysical stream復帰の時機と競合する。bounded queueとsession resetが最終的な復旧に寄与したと考えられるが、
restart直後のhandshake失敗原因は確定していない。
