# 0017: 応答障害はボード起動ごとに1回だけ有効にする

## 状態

採用

## 背景

FC-100 Serverのresponse fault injectionはadapter stateにdrop countと開始時刻を保持する。remote health recoveryで
`net_kernel`を再起動するとServer adapterも再生成され、従来は同じfault設定が初期値から再armされた。このため最初のblackoutから
回復した後に2回目のblackoutが始まり、30秒後のqueue / memory snapshotを正常なsettlingとして評価できなかった。

反復faultが必要な試験は存在するが、1回の障害からの回復とsettlingを測る試験では、adapter lifecycleとfault回数を結びつけない。

## 判断

`MODBUS_FAULT_REARM_ON_RESTART`を追加し、defaultを`false`とする。最初のServer adapterには設定した
`MODBUS_FAULT_DROP_RESPONSES`を渡す。remote distributionを再起動してreplacement adapterを作るときはdrop countを0にする。

これによりfaultはdevice boot中の最初のadapterだけにarmされ、最大1回となる。device rebootでは設定を再びarmする。意図的に
adapterごとの反復faultを試す場合だけ`MODBUS_FAULT_REARM_ON_RESTART=true`を指定する。

このpolicyはrobot exampleのremote distribution restart経路で適用する。FC-100 wire protocol、AVModbus core、再利用元の
`DisterlProbe.ResponseFault`は変更しない。

## 影響

2026-10-23の3台実機試験では、Sensorsが103 FC-100 response failureを発生させた後にdistributionを再起動した。replacement
adapterではfaultが再armされず、同じproducerが未確認sequenceから再開してDrive / Sensorsとも16 / 16 messagesを完全配送した。
30秒後は両adapterのqueueが0となり、replacement adapter起動から約101秒後まで2回目のfaultは発生しなかった。

faultが発火する前に別理由でdistributionを再起動した場合も、replacement adapterではfaultをarmしない。これは「必ず1回」ではなく
「device boot中に最大1回」の診断policyである。またdistribution reconnectは未配送のapplication start messageを復元しないため、
fault開始とworkload開始が重なる試験ではapplication側の明示的な開始確認が別途必要である。
