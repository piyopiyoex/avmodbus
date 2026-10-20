# readiness ACK による idle connection recovery — 2026-10-20

## 目的

concurrent traffic を無効にした idle な3-node構成で、SensorsだけのFC-100 response blackoutをremote側から検出する。application ACKに
依存せずSensors distributionを再起動し、Drive connectionを維持したまま再接続できるか確認する。あわせてrestart回数の上限を実機で
確認する。

## 実装

- readiness ACKへdistribution connection IDを追加し、古いconnectionのACKを無視する
- remote heartbeatを`receive after`から明示的なtimer messageへ変更し、他のmailbox trafficと独立させる
- `RobotSim.RemoteHealth`をpure state machineとして追加する
- ACK期限超過時のrestart回数をboard boot単位で制限する
- `net_kernel.stop/0`後に`:net_kernel`の登録解除を50 ms間隔、最大40回確認してから再開する

新機能は`ROBOT_MULTINODE_REMOTE_HEALTH_ENABLED=false`が既定である。hostではstale ACK、期限境界、restart消費、上限到達時の1回だけの
報告、connection更新後もboot単位のbudgetを保持することを含む60 testが成功した。

## 実機条件

- 3 × Seeed Studio XIAO ESP32-C5
- shared two-wire RS485、115,200 baud
- FC-100 chunk payload 96 bytes、poll interval 20 ms
- AtomVM v0.7.0-beta.0 と既存multi-connection local patch
- concurrent traffic / application soakは無効
- Sensors heartbeat 10,000 ms、readiness ACK timeout 25,000 ms
- Sensors restart上限 1回 / boot
- Sensorsは起動60秒後から180 FC-100 responseを破棄

試験firmwareはDrive 254,476 bytes、Sensors 254,668 bytes、Controller 256,916 bytesだった。

## 最初の試行で見つかった lifecycle race

最初の実装は`net_kernel.stop/0`が`:ok`を返した直後に`net_kernel.start/2`を呼んだ。ACK欠落28,553 msの検出には成功したが、旧
`:net_kernel` processがまだ登録されており、startは`{:already_started, pid}`で失敗した。これは前回のtraffic ACK試験でrestartが成功した
ことがtiming依存だったことを示す。

固定sleepではなく、登録解除を最大2秒までpollする処理を追加した。修正版のAtomVM compatibility checkとPackBEAM buildは成功した。

## 修正版の結果

| 時刻 | 観測 |
| --- | --- |
| 20:53:54.526 | Sensorsが最初のFC-100 responseを破棄 |
| 20:54:20.620 | ACK欠落28,524 msを検出し、connection `794793348`のrestartを開始 |
| 20:54:20.767 | 新しいServer adapterをsession `2405874065`でopen |
| 20:54:20.799 | Sensors distributionをconnection `3859813543`で再開 |
| 20:54:22.913 | Controllerがpeer session changeを検出 |
| 20:54:26.248 | ControllerがSensorsをreconnectとして受信 |
| 20:54:26.963 | Sensorsが新connection用readiness ACKを受信 |
| 20:54:29.442 | Sensors recovery probeが成功 |
| 20:54:31.228 | 接続を維持していたDriveのrecovery probeが成功 |
| 20:54:31.230 | Controllerがrecovery completeを記録 |

restart開始から新distribution startまでは179 ms、Controllerのreconnect認識までは5,628 ms、両probe完了までは10,610 msだった。
restart時のblocking read終了とControllerのpeer session changeに伴うcrash reportは表示されたが、新handshakeを阻害しなかった。

## Bounded restart

Server adapterの再生成でfault delayも再armされ、20:55:20.792に2回目のblackoutが始まった。20:55:49.032にSensorsは
`remote health restart budget exhausted ... restarts=1`を記録し、2回目の`net_kernel` restartは行わなかった。これにより、連続する
通信障害で無限restartしないことを実機でも確認した。

これはboot中のrestart回数を制限するだけである。障害解消後にbudgetを自動補充せず、rebootするとbudgetは初期化される。

## 通常構成への復帰確認

試験後、faultとremote healthを無効にした通常firmwareを3台へflashした。サイズはDrive 254,696 bytes、Sensors 254,668 bytes、
Controller 256,916 bytesだった。両distribution linkとremote probe、3-step sensor-driven missionが成功し、最終stateは
`%RobotSim.Rover{x_mm: 200, y_mm: 0, heading_deg: 90}`だった。

## 結論

readiness heartbeatをACK付きのconnection health probeとして使うことで、application trafficがない状態でも非対称half-open connectionを
remote側から解消できた。ControllerのDrive linkは維持され、Sensorsだけが新しいdistribution connectionへ移行した。

この検出器はopt-inの実験機能である。25秒timeoutは今回の診断profileであり、任意負荷で安全な値ではない。複数connectionを持つnode、
個別peer disconnect、durable mission recovery、物理的なcable抜き差しは引き続き別課題とする。
