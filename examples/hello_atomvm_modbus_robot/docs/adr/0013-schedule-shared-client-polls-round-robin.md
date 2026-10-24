# 0013: 共有Clientのpollをラウンドロビンで直列化する

## 状態

採用

## 背景

Controller の Drive / Sensors adapter は1個の `AVModbus.Client` を共有するが、従来は各 adapter が独立した timer で poll を開始していた。
AVModbus Client は physical transaction を直列化できる一方、request の deadline には Client mailbox で待つ時間も含まれる。

breadboard branch の反復切断試験では、到達不能な Unit 2 の request 待ち中に Unit 1 の request もqueueへ入り、送信開始前に約2秒の
deadlineを使い切った。15:05:38からUnit 1 / 2の両方でtimeoutが続き、15:06:27に正常なDrive connectionも`net_tick_timeout`となった。
Unit 1は15:06:47から断続的に成功したため、physical trunkの恒久的な断線ではなくshared Clientのhead-of-line deadline starvationと判断した。

## 判断

Controller の2個の `DisterlProbe.ModbusUART` adapterを、1個の`DisterlProbe.PollScheduler`でround-robinに駆動する。

- adapterは起動時に自分でpollを開始せず、schedulerから`:poll` tokenを受け取る
- tokenを持つadapterだけがAVModbus Clientへrequestを送る
- 成功、timeout、decode error、同期send errorのいずれでも完了後にtokenをschedulerへ返す
- schedulerは既存のpoll intervalを置いた後、次のadapterへtokenを渡す
- Drive、Sensorsの登録順を固定するが、各transaction完了ごとに末尾へ戻してround-robinを維持する
- 単一peerの2-node exampleはschedulerを渡さず、従来のself-scheduled pollを維持する

AVModbus core、FC-100 wire protocol、Unit別sequence / ACK / session stateは変更しない。

## 影響

到達不能なpeerのrequestがtimeoutしても、次の正常peerは新しいdeadlineでtransactionを開始できる。2026-10-21の実機再試験では、
Sensors branch切断中にUnit 2が2秒timeoutを繰り返す一方、Unit 1は約180–225 msで成功し続け、Drive distribution connectionと
readiness heartbeatを維持した。Sensors branch復帰後は手動Controller resetなしでSensors / Drive両probeまで完了した。

到達不能なpeerもround-robinの各turnでtimeout時間を消費するため、正常peerのlatencyとthroughputは悪化する。schedulerはController内の
単一processであり、adapter crash時の自動登録解除やdynamic peer追加は実装していない。公平なtransaction開始を提供するが、distribution
handshakeの成功時間、application workloadの再開、任意の物理配線でのfault isolationは保証しない。
