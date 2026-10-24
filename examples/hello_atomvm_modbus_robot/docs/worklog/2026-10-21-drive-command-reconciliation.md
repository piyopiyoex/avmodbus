# Drive command結果の照合 — 2026-10-21

## 目的

movementを実行したDriveがreply送信前にrebootした場合、Controllerがsame-ID commandを新bootで再実行せず、確定できないoutcomeを
明示してmissionを停止できることを確認する。

## 実装

Driveへ起動単位のboot IDとidentity requestを追加した。sensor-driven missionは開始時のboot IDを取得し、すべてのmovementとfinal statusへ
同じexpected boot IDを付ける。同一bootでは従来のbounded request cacheを使用し、異なるbootではcommandを実行せず
`indeterminate_command`を返す。

host testでは次を確認した。

- Drive identityが同じprocess内で安定する
- current boot向けguarded commandは実行される
- stale boot向けguarded commandはrover stateを変更しない
- 同一boot内のreply lossはsame-ID retryで1回だけ実行される
- mission途中のboot changeは次のmovementを実行せずstep failureになる

最終確認ではroot projectが228 tests + 6 properties、既存disterl exampleが67 tests、robot exampleが67 testsで、すべてfailure 0だった。
Drive、Sensors、Controllerの3 roleすべてで`mix atomvm.check`と`mix atomvm.packbeam`に成功した。

## 実機条件

- 3 × Seeed Studio XIAO ESP32-C5
- breadboard railによるcontinuous A/B trunkとnode別branch、共通GND
- 115,200 baud、FC-100 chunk payload 96 bytes
- AtomVM v0.7.0-beta.0と既存multi-connection local patch
- Controllerはguarded mission対応firmware、image data 263,540 bytes
- Driveはguarded command対応firmware、image data 260,748 bytes
- Sensorsは既存の通常firmware

## 通常baseline

DriveとControllerを更新後、ControllerはDrive / Sensors両方へ接続し、両probeを完了した。mission開始時にDrive identityを取得し、
request `2695655373`から3件のguarded movementとfinal statusを実行した。すべてattempt 1で成功した。Sensors sequence 4–6と
継続中のstateを使ったため、final stateは`{x_mm: -100, y_mm: 0, heading_deg: 180}`だった。

## Reply loss後のDrive再起動

Driveだけ`ROBOT_DRIVE_DROP_FIRST_REPLY_PER_REQUEST=true`でrebuild / flashし、Controllerをresetして新しいmissionを開始した。

1. Controllerがrequest `3061778947`、command `{:turn, :right, 90}`を旧Driveへ送った。
2. Driveがmovementを実行し、`injected reply loss request_id=3061778947`を記録した。
3. reply未受信の状態でDriveをUSB経由でresetした。
4. ControllerはDrive carrier session changeを検出し、Drive distributionを再接続した。
5. Drive / Sensors両方へのrecovery probeが成功した。
6. 60秒のapplication timeout後、Controllerは同じrequest ID、command、expected boot IDでattempt 2を送った。
7. 新Driveはboot ID不一致を検出し、movementを実行しなかった。

Controllerの最終結果は次のとおりだった。

```text
{:error, {:indeterminate_command, 3061778947, 717108360, 3388176805}}
{:sensor_mission_failed, 1,
 {:indeterminate_command, 3061778947, 717108360, 3388176805}}
```

旧boot IDは`717108360`、新boot IDは`3388176805`だった。旧bootではmovementを実行済みだが、その事実を新bootへ永続化していないため、
Controllerは完了とも未実行とも決めずindeterminateとして停止した。新bootで同じmovementを再実行しなかったことが重要な結果である。

## 復元確認

Driveをreply-loss無効の通常firmwareへ戻し、Controllerをresetした。Drive / Sensorsの接続と両probeに続き、guarded 3-step missionと
final statusが成功した。fresh DriveとSensors sequence 10–12に対応するfinal stateは
`{x_mm: 0, y_mm: 200, heading_deg: 90}`だった。3台に診断用reply-loss設定は残していない。

## 結論

boot guardは、reply lossとDrive rebootが重なった未確定commandを新bootで自動再実行しない。これはdurable exactly-once、state復元、
自動mission resumeではない。検出後のoperator判断または上位application reconciliationは別の課題として残る。
