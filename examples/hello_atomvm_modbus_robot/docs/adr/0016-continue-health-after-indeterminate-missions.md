# 0016: 結果不明のミッション後もヘルスチェックループを継続する

## 状態

採用

## 背景

Drive boot guardは、reply未受信のmovementを新bootで自動再実行せず、`indeterminate_command`としてmissionを停止する。
従来のControllerはmission errorをremote初期化失敗と同様に扱い、無限sleepへ入っていた。この間はreadiness ACKとlease評価も
停止するため、正常なremoteからはControllerが応答しないように見える。また新しいDriveのvolatile stateを確認するには
Controllerを再起動して新しいmissionを始める必要があった。

旧bootでcommandが実行されたかは永続logなしには確定できない。したがってmovementの再送や自動resumeは行わず、Controllerの
availabilityとoperatorが判断するための観測情報だけを回復する。

## 判断

ADR 0014の「application error時はControllerを停止する」という判断を、この場合に限って置き換える。
mission errorではmissionを終了扱いとし、Controllerのhealth loopを継続する。errorが
`indeterminate_command`を含む場合は、別の`RobotSim.RecoveryWorker`を1個起動する。

Recovery workerは次を順に実行する。

1. 現在のDrive boot IDを取得する
2. そのboot IDでguardした新しいrequest IDの`:status`を送る
3. boot ID、rover state、元のmission errorをsnapshotとしてControllerへ返す

Controllerはsnapshotまたは取得失敗をlogへ記録し、どちらの場合もhealth loopを継続する。recovery中もController processは
readiness heartbeat、connection更新、lease評価を処理する。snapshotはread-only evidenceであり、movementを再送せず、mission、
soak、concurrent trafficを自動開始しない。indeterminate以外のmission errorでもhealth loopは継続するが、snapshotは取得しない。

transport、FC-100 wire protocol、AVModbus coreは変更しない。

## 影響

2026-10-23の3台実機試験では、request `3901293760`のreplyを失った直後にDriveをresetした。新bootは旧boot向けretryを
`indeterminate_command`として拒否し、missionは停止した。その後Controllerは新boot `4242226695`を取得し、guarded `:status`で
初期state `(0, 0, 0°)`を記録した。snapshot後も30秒以上両linkのtrafficを処理し、無限sleepへ入らなかった。

snapshotは新bootの現在値であり、旧bootでのcommand outcomeや失われたrover stateを復元しない。status取得中にbootが再度変わる場合、
timeoutする場合、またはdistributionが利用できない場合は失敗を記録するだけである。operatorによるreconciliation、新mission開始、
state永続化は引き続き別の課題とする。
