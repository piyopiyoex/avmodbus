# Stage 7 transport復帰後のrestart保留

## 目的

長時間のSensors branch切断中に`net_kernel.stop/0`を呼び出すcurrent policyと、physical transportの復帰後までrestartを保留する
policyを比較できるようにする。timeoutやrestart回数は増やさず、restart budgetを消費する時点だけを変更する。

## 設計

`DisterlProbe.ModbusUART`のServer adapterへ任意のtransport activity observerを追加した。observerを指定した場合だけ、設定時間を
超えて有効なFC-100 exchangeが途切れた後、最初のexchangeと、設定回数に達するまでの連続exchangeを通知する。通常pollごとの
通知は行わない。adapterは観測だけを担当し、distribution restartの判断はrobot exampleに残す。

robot exampleのremote health stateは、ACK timeout時に次の2経路を選べる。

- 既定のcurrent policy: 直ちにboot単位のrestart budgetを1回消費してrestartする。
- opt-inのdeferred policy: `restart_pending`を記録するがbudgetは消費せず、transport ready通知後に確保する。

transport readyは、remote Serverが90秒を超えるexchange gap後に、有効なFC-100 exchangeを2回連続して受理した状態とした。
同じdistribution connectionのreadiness ACKが先に戻った場合はpendingを解除し、restartしない。

設定は次のとおりである。

```sh
ROBOT_MULTINODE_REMOTE_HEALTH_ENABLED=true
ROBOT_MULTINODE_DEFER_RESTART_UNTIL_TRANSPORT_READY=true
ROBOT_MULTINODE_TRANSPORT_READY_CONFIRMATIONS=2
```

既定値はdeferred policy無効のままであり、AVModbus coreとFC-100 wire formatは変更していない。

## ホスト検証

`ModbusUART`では、長時間gap後の通知が指定回数で止まることと、通常exchangeでは通知しないことをtestした。remote healthでは、
timeoutだけではbudgetを消費しないこと、transport ready後に1回だけ消費すること、同じconnectionのACKとstale ACKを区別することを
testした。

```text
hello_atomvm_modbus_disterl: 80 tests, 0 failures
hello_atomvm_modbus_robot:   127 tests, 0 failures
```

両exampleで`mix format --check-formatted`も成功した。

Drive / Sensorsではdeferred policyを有効にし、Controllerを含む3 roleすべてで`mix atomvm.check`と
`mix atomvm.packbeam`に成功した。`No avm_deps directory found`はstandard libraryをAtomVMのlib partitionへ導入済みの構成での
既知の案内であり、build failureではない。

## 実機比較

最初の試行では、Sensorsがconsole監視開始前の初回接続でrestart budgetを1回消費していた。約220秒のFC-100 exchange gap後、
`restart_deferred`、`transport_resumed`、2回目の有効exchangeで`transport_ready`を記録し、切断中に`kernel_stop_requested`は
発生しなかった。budget枯渇のためrestartは拒否され、Drive connectionは維持された。この試行はtransport observerの実機確認には
使えるが、deferred restart成功の比較には使わない。

この試行ではbudget枯渇後の次のhealth tickが再び`restart_deferred`を出す状態遷移も見つかった。budgetが残っていない場合は
deferせず、枯渇を1回だけ報告して以後`waiting`にするhost修正を加えた。

状態機械修正後のSensorsを、接続済みControllerが動作している状態でflashし直した。新boot `2047011669`は起動約6.4秒後に
connection `2038774249`のreadiness ACKを受信し、restart budget未使用で試験を開始した。Driveはconnection `695747084`を
維持した。

Sensors branch切断後の主なeventは次のとおりだった。利用者の`removed` / `restored`応答は物理操作後に届くため、切断時間は
remoteで観測したFC-100 exchange gapを用いる。

| Event | 時刻 | 結果 |
| --- | --- | --- |
| 最後のSensors readiness ACK | 09:59:24 | connection `2038774249` |
| Controller `net_tick_timeout` | 10:00:33 | Sensors connectionだけをclose |
| Controller `stale_detected` | 10:00:39 | Driveは継続 |
| `restart_deferred` | 10:01:22 | ACK gap 118,530 ms、`restarts=0` |
| `transport_resumed` | 10:05:26.294 | FC-100 exchange gap 350,768 ms、confirmation 1 / 2 |
| `transport_ready` | 10:05:26.792 | 498 ms後、confirmation 2 / 2 |
| `kernel_stop_requested` | 10:05:26.845 | transport readyより前には未実行 |
| `kernel_stop_completed` | 10:05:26.912 | requestedから約67 ms |
| `kernel_start_succeeded` | 10:05:27.015 | start開始から約89 ms |
| `restart_succeeded` | 10:05:27.037 | 新connection `2205303859` |
| Controller `remote_reconnected` | 10:05:31.648 | transport readyから約4.9秒 |
| `readiness_acknowledged` | 10:05:32.586 | transport readyから約5.8秒 |
| `recovery_verified` | 10:05:37.426 | transport readyから約10.6秒 |
| `peer_maintained` | 10:05:37.436 | Drive connection `695747084` |

Sensorsのfree heapは`restart_deferred`時89,812 bytes、`transport_ready`時83,884 bytes、restart区間のminimum watermarkは
79,784 bytesだった。`kernel_stop_completed`直後には102,668 bytesとなり、以前のcurrent policy試験で記録した
`net_kernel_stop_timeout`や14,428 bytesまでの低下は再現しなかった。

ControllerのUnit 1 transaction failureは試験中3のままで、Drive ACKも継続した。Unit 2 failureは切断前116から復旧時270へ
増えた。切断中に観測したSensors向けqueueは最大32 bytes / 4 chunks、reconnect直後のhandshakeでは267 bytes / 5 chunksとなり、
10:05:47までにglobal queueは0へdrainした。global rejectionは0だった。

09:59:10–10:07:30の3 role logを`RobotSim.EnduranceReport`で集計した。connection eventは
`restart_deferred`、`transport_resumed`、`transport_ready`、kernel stop / start、`restart_succeeded`、
`remote_reconnected`、`recovery_verified`、`peer_maintained`が各1件で、failure eventとbudget exhaustionは0件だった。
periodic memory sampleの最小値はSensors 87,404 bytes、Drive 85,724 bytes、各watermarkは79,784 bytes / 80,060 bytesだった。
このwindowではtraffic campaignを実行していないため、reportの総合`successful`はfalseになる。これはconnection recovery失敗ではなく、
集計器がtraffic完了を総合成功の必須条件としているためである。

## 判断

- current policyは約97秒の操作応答区間で、物理復帰前の`net_kernel.stop/0`がtimeoutした。
- deferred policyは約350.8秒のFC-100 exchange gapでも、切断中にrestart budgetを消費しなかった。
- 2回の有効exchange後に同じbudgetを消費してrestartし、board resetなしでdistributionとapplication probeを復旧した。
- 正常なDrive connectionは維持され、ControllerとDriveのresetは不要だった。
- timeout延長やrestart上限増加は行っていない。
- current policyとdeferred policyの切断時間は同一ではない。deferred policyがより長いgapで成功したことは有力な比較結果だが、
  任意の通信断時間、配線条件、負荷での復旧を保証しない。

当初の確認項目はすべて達成した。

- [x] 切断中に`restart_deferred`を記録し、restart budgetが0のままである。
- [x] 復線後に`transport_resumed`、`transport_ready`の順で記録する。
- [x] `kernel_stop_requested`が`transport_ready`より前に発生しない。
- [x] Sensorsの新connectionで`readiness_acknowledged`、Controllerの`remote_reconnected`、両peerのprobe成功へ到達する。
- [x] Drive connection ID、Unit 1 polling、queue、3台のmemory推移を記録する。

単発の有効exchangeはresponseがControllerへ届いたことを保証しないため、既定2回を比較条件にする。Serverがrequestを受信し続ける
非対称response blackoutではexchange gapが発生しないため、このpolicyの対象外とする。
