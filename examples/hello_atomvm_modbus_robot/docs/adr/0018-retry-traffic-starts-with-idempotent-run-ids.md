# 0018: traffic startをACK付きで再送しrun IDで重複排除する

## 状態

採用

## 背景

concurrent traffic probeは、Controllerから各remoteへstart messageを1回だけ送っていた。Sensors response blackout中に
このmessageを送った実機試験では、Drive producerだけが開始し、Sensorsはdistribution再接続後も`started=false`、0 / 16のまま
collectorがtimeoutした。transportとdistributionの再接続は、未配送のapplication messageを復元しない。

一方、同じstartを無条件に再送すると、remoteが最初の要求を受理した後にACKだけを失った場合、同じrunのproducerを複数起動する。

## 判断

Controllerはroleごとにstart workerを起動し、remoteから`run_id`付きstart ACKを受信するまで既存のtraffic ACK timeoutとretry
budgetを使って同じstartを再送する。collectorは別processのままなので、片方のroleのstart ACK待ちがもう片方のsample受信や
Controller health loopを止めない。

remoteはboard boot中に最後に受理したtraffic `run_id`をreceive loopのstateとして保持する。同じ`run_id`のstartを再受信した場合は
ACKだけを返し、producerを増やさない。このstateはremote側`net_kernel`のstop / restartをまたいで保持する。異なる`run_id`は新しい
probeとして受理する。

faultとの時刻関係を再現可能にするため、Controllerには`ROBOT_MULTINODE_TRAFFIC_START_DELAY_MS`も追加する。delayはmission完了後に
message timerで設定し、Controller health loopをblockしない。defaultは0である。

## 影響

2026-10-23の3台実機試験では、Sensors blackout中に開始したrunのstart ACKが複数回timeoutした。Sensors distribution再起動と
再接続後、後続retryでSensors producerが開始し、Drive / Sensorsとも16 / 16 messagesをmissing、duplicate、out-of-order、invalid
すべて0で完了した。Sensorsの開始はDriveより51,778 ms遅れた。

この重複排除stateはvolatileであり、physical device rebootをまたぐdurable exactly-once startを提供しない。また現在のexampleは同じ
remoteでconcurrent traffic probeを1 runずつ実行する前提で、一般的なjob registryではない。AVModbus core、FC-100 wire protocol、
AtomVM runtimeは変更しない。
