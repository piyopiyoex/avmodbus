# 0014: ミッションはControllerのヘルスチェックループ外で実行する

## 状態

採用

## 背景

Controller は Drive / Sensors の readiness heartbeat を受信し、connection ID 付き ACK を返しながら role 別 lease を評価する。
従来の sensor-driven mission は同じ Controller process から `SensorMission.run/3` を同期的に呼び出していたため、remote reply を
待っている間は readiness message を処理できなかった。

2026-10-21の物理切断試験に先立つ診断では、障害のない通常mission中にもSensorsのreadiness ACK gapが25,537 msとなり、
25秒のremote health timeoutを障害と誤判定した。timeoutへ大きな余裕を持たせる必要は残るが、missionの待ち時間までhealth判定を
止める構造は避ける。

## 判断

sensor-driven missionをlocalの`RobotSim.MissionWorker` processで実行する。Controller processは従来のreceive loopを継続し、
mission中も次を処理する。

- Drive / Sensorsのreadiness heartbeatとconnection ID付きACK
- role別readiness leaseの期限評価
- concurrent trafficの完了通知とmetrics
- remote boot / connection generationの更新

Workerは完了時に`{RobotSim.MissionWorker, worker_pid, result}`をownerへ送り、Controllerは起動したworker PIDと一致する結果だけを
受理する。mission成功後に従来どおりsoakとconcurrent trafficを開始し、application error時は初期化失敗として停止する。

transport、FC-100 wire protocol、AVModbus coreは変更しない。

## 影響

mission commandのreply待ちとreadiness health処理が独立する。2秒announce、10秒ACK timeoutの診断構成では、3-step missionと
その後を含む約86秒の同時console監視中にSensorsのhealth restart、timeout、restart budget消費は発生しなかった。

これはreboot中の未確定commandを解決する仕組みではない。Drive / Sensorsのvolatile state、request cache、sensor sequenceは
永続化されず、進行中missionの自動resumeとstate reconciliationも行わない。起動直後のremote probe、recovery probe、任意のsoakは
引き続き同期処理を含むため、すべてのController処理を非同期化する判断でもない。
