# 0011: ACK timeout 時は remote 側 distribution を再起動する

- Status: accepted for the experimental probe
- Date: 2026-10-20

## 背景

SensorsのFC-100 responseだけを連続して破棄すると、Controllerは`net_tick_timeout`でconnectionを終了する一方、Controllerからの
requestを受信しているSensorsは古いconnectionを保持した。physical pollingが復帰しても新しいhandshakeは始まらず、application ACKの
same-sequence retryだけでは回復できなかった。

AtomVM v0.7系の`net_kernel`には特定nodeだけを明示的にdisconnectするpublic APIがない。Controller全体の`net_kernel`を再起動すると
正常なDrive connectionも失う。Drive / Sensors側はdistribution connectionを1本だけ持つため、remote側だけなら`net_kernel`全体を
停止して再開できる。

## 判断

- concurrent traffic producerは、各started / sample / finishedで最初のACK timeoutだけをlocal lifecycle ownerへ通知する
- `ROBOT_MULTINODE_RESTART_ON_TRAFFIC_ACK_TIMEOUT=true`のremoteだけが通知時に`net_kernel.stop/0`を実行し、同じrole、UART設定、
  cookieでdistributionを再開する
- Drive / Sensors application processとproducerは停止せず、未確認run ID / sequenceを保持する
- board boot IDとは別にdistribution connection IDをreadiness messageへ追加する
- ControllerはPID、boot ID、connection IDがすべて一致する場合だけheartbeatをduplicateとみなす
- 設定のdefaultは`false`とし、通常動作や一般のrobot commandへ自動適用しない
- AVModbus core、FC-100 wire protocol、AtomVM runtimeは変更しない

この判断はboot IDを定義した[ADR 0006](0006-identify-remote-boots-with-session-ids.md)を置き換えず、同一boot内のdistribution lifecycleを
識別するconnection IDを追加する。

## 影響

- remote側のstale connectionを明示的に終了し、Controllerの他方のconnectionを維持したまま新しいhandshakeを開始できる。
- producerはconnectionより長く生存するため、再接続後に同じsequenceをretryできる。
- `net_kernel.stop/0`はremoteの全distribution connectionを停止する。この実験のremoteは1 connectionだけだが、複数peerを持つnodeへ
  そのまま一般化できない。
- ACK timeoutはconnection failure以外でも発生し得る。誤検出時には正常なconnectionを再起動するため、opt-inの診断機能として扱う。
- 1 message内では最初のtimeoutだけを通知する。restart失敗時の無制限loopやdurable workload recoveryは実装しない。
- adapter再生成時にdiagnostic response faultのstateも初期化され、設定したdelay後に再度armされる。
