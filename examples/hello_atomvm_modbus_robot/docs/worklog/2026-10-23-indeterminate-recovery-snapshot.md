# 結果不明ミッション後の復旧記録 — 2026-10-23

## 目的

Drive rebootをまたぐ未確定commandを検出した後、movementを自動再実行せずに次を満たすことを確認する。

- missionだけを停止し、Controllerのreadiness health loopを継続する
- 新しいDrive bootのread-only stateを取得してoperator向けの証拠を残す
- snapshot後もDrive / Sensors両linkを処理する

## 実装

`RobotSim.RecoveryWorker`を追加した。mission errorが`indeterminate_command`を含む場合、Controllerとは別processで現在のDrive
boot IDを取得し、そのIDでguardした`:status`を送る。結果にはboot ID、rover state、元のmission errorを含める。

Controllerはmission error時に停止せずreceive loopへ戻る。snapshot workerの完了を待つ間もreadiness messageとremote connection
更新を処理する。snapshotからmovement再送、mission再開、soak、concurrent trafficは開始しない。

host testでは次を確認した。

- current Drive bootにguardされた`:status`がrover stateを変更せずsnapshotを返す
- identity取得後にDrive bootが再度変わった場合はsnapshot成功とせず`indeterminate_command`を返す
- identity timeoutを待つ間もowner processが別のhealth messageを処理できる

最終確認ではroot projectが228 tests + 6 properties、既存disterl exampleが67 tests、robot exampleが70 testsで、すべてfailure 0だった。
Drive、Sensors、Controllerの3 roleすべてで`mix atomvm.check`と`mix atomvm.packbeam`に成功した。

## 実機条件

- 3 × Seeed Studio XIAO ESP32-C5
- breadboard railによるcontinuous A/B trunkとnode別branch、共通GND
- 115,200 baud、FC-100 chunk payload 96 bytes
- AtomVM v0.7.0-beta.0と既存multi-connection local patch
- Controllerはrecovery snapshot対応firmware、image data 265,968 bytes
- Driveはreply-loss診断firmware、image data 262,004 bytes
- Sensorsは既存の通常firmware

## 応答消失後のDrive再起動

Driveを`ROBOT_DRIVE_DROP_FIRST_REPLY_PER_REQUEST=true`でbuildし、Controllerからmissionを開始した。

1. Controllerがrequest `3901293760`、command `{:turn, :right, 90}`を旧Driveへ送った。
2. Driveがmovementを実行し、最初のreplyを破棄した。
3. reply未受信のままDriveをUSB経由でresetした。
4. ControllerはDrive distributionを再接続し、Drive / Sensors両方へのprobeを完了した。
5. application timeout後のsame-ID retryを新Driveがboot ID不一致として拒否した。
6. Controllerはmissionを停止し、health loopを継続した。
7. Recovery workerが新Drive boot IDを取得し、新しいrequest IDでguarded `:status`を送った。

観測したmission errorは次のとおりだった。

```text
{:sensor_mission_failed, 1,
 {:indeterminate_command, 3901293760, 1076154800, 4242226695}}
```

取得したsnapshotは次のとおりだった。

```text
boot_id=4242226695
state=%RobotSim.Rover{x_mm: 0, y_mm: 0, heading_deg: 0}
```

診断firmwareはrequestごとに最初のreplyを破棄するため、snapshotの`:status`もattempt 1ではreplyを失った。60秒後の
same-ID retryが同じbootのcache済みresultを取得し、state transitionは発生しなかった。snapshot記録後も30秒以上、Controllerは
Drive / Sensors両方のcarrier trafficを処理した。

## 復元確認

Driveをreply-loss無効の通常firmwareへ戻し、Controllerをresetした。Drive / Sensorsの接続、両probe、3-step sensor mission、
final statusがすべて成功した。最終stateは`{x_mm: 0, y_mm: 200, heading_deg: 90}`だった。3台に診断用reply-loss設定は残していない。

## 操作者による新しいミッション開始

Recovery snapshotと通常firmwareへの復元を確認した後、operator操作としてControllerだけを再度resetした。Controllerは新しい
request ID rangeを生成し、現在のDrive boot IDを取得して別の3-step missionを開始した。取得途中からのconsole logではstep 3の
guarded movement、final `:status`、mission完了を確認し、その後もcarrier trafficが継続した。

Driveはresetしていないため、rover stateは前のmissionから保持された。今回のmissionは保持中のstateから継続し、最終stateは
`{x_mm: 0, y_mm: 200, heading_deg: 0}`だった。Controller resetは新しいmissionを明示的に始めるoperator操作として利用できるが、
Drive stateを初期化する操作ではない。snapshotの妥当性判断、state補正、mission選択を行う対話的な確認protocolも実装していない。

## 結論

indeterminate outcomeはmissionの停止条件であるが、Controller全体の停止条件ではない。新bootのread-only snapshotを取得しながら
health loopを継続できた。snapshot確認後のController resetで新しいmissionを開始できたが、これは自動resumeではなく、保持中の
Drive stateから別missionを実行するoperator操作である。snapshotは旧bootでの実行有無を解決せず、state復元も提供しない。
