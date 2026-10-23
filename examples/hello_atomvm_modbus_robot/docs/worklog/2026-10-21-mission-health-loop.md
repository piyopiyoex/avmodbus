# ミッション実行とヘルスチェックループの分離 — 2026-10-21

## 目的

Controllerがsensor-driven missionのremote replyを待つ間もreadiness heartbeatを処理し、remote healthのfalse positiveを
避けられることを確認する。

物理RS485切断試験では、同期mission中にSensorsのreadiness ACK gapが25,537 msとなり、25秒timeoutで不要なdistribution restartを
起こした。timeoutを延ばすだけでなく、application待ちとhealth loopを構造的に分離する。

## 実装

`RobotSim.MissionWorker`を追加し、`SensorMission.run/3`をlocal processで実行するようにした。Controllerはworker PIDを保持したまま
従来のreceive loopへ入り、mission result、readiness heartbeat、lease expiry、traffic通知を同じloopで処理する。

host testでは次を確認した。

- missionがownerとは別processで3 stepを完了し、結果をworker PID付きで通知する
- workerがsensor timeoutを待っている間もownerが無関係なhealth messageを受信できる

最終確認ではroot projectが228 tests + 6 properties、既存disterl exampleが67 tests、robot exampleが63 testsで、すべてfailure 0だった。
robot exampleはDrive、Sensors、Controllerの3 roleすべてで`mix atomvm.check`と`mix atomvm.packbeam`に成功した。

## 実機条件

- 3 × Seeed Studio XIAO ESP32-C5
- breadboard railによるcontinuous A/B trunkとnode別branch、共通GND
- 115,200 baud、FC-100 chunk payload 96 bytes
- Driveは通常firmware
- Sensorsは`ROBOT_MULTINODE_ANNOUNCE_MS=2000`、remote health有効、ACK timeout 10,000 ms、restart上限1回 / boot
- Controllerはmission workerを含むfirmware

USB書き込み時、3台を同じmultiport hubへ接続した構成ではControllerで`Write timeout`と
`Serial data stream stopped`が発生した。ControllerだけをPCのroot portへ直結し、Drive / Sensorsをhub配下に残すと、同じ115,200 baudの
esptool書き込みが直ちに成功した。これはRS485 transportの結果ではなく、再現作業時のUSB接続上の注意として記録する。

## 診断結果

SensorsとControllerを起動し、3台のconsoleを同時に約86秒監視した。監視開始時点でmissionが始まっていたため、Sensors sampleは
sequence 4–6から継続した。

| 確認項目 | 結果 |
| --- | --- |
| Drive / Sensors logical traffic | 継続 |
| 3-step sensor-driven mission | 成功 |
| 最終status | `{x_mm: 100, y_mm: 0, heading_deg: 180}` |
| mission中のSensors health restart | 0 |
| readiness ACK timeout | 0 |
| restart budget exhausted | 0 |
| mission完了後の2秒heartbeat traffic | 60秒以上継続 |

10秒の診断timeoutを十分に超えてheartbeat trafficが継続し、従来の同期missionで見られたfalse positiveは再現しなかった。
最終stateは継続中のDrive / Sensors stateに対応する値であり、fresh boot reference missionの期待値ではない。

## 通常構成への復元

SensorsとControllerをremote health無効、announce interval 30,000 msの既定設定でrebuild / flashした。書き込んだimage dataは
Sensors 258,728 bytes、Controller 261,548 bytesで、どちらもhash verificationに成功した。

通常構成ではDrive、Sensorsの順にdistribution connectionを確立し、両probeを完了した。接続直後にUnit 1で1回のpoll timeoutが
あったがretryで回復した。fresh Sensorsのsequence 1–3によるmissionは3 stepとfinal statusを完了した。Driveはこの確認前にresetして
いないため、最終stateは継続中のrover stateに対応する`{x_mm: -100, y_mm: 0, heading_deg: 270}`だった。

## 結論

missionをworkerへ移したことで、Controller health loopはremote reply待ちから独立した。今回の診断profileではmission中も10秒以内の
health条件を維持し、不要なdistribution restartを発生させなかった。

未確定movement commandのreconciliation、mission workerのdurable ownership、rebootをまたぐ自動resumeは未実装である。これらは
health loop分離とは別のapplication recovery課題として残す。

同日後続の[Drive command outcomeのreconciliation](2026-10-21-drive-command-reconciliation.md)で、未確定commandを新bootで
再実行せずindeterminate outcomeとして停止するboot guardを追加した。durable ownership、state復元、自動resumeは引き続き提供しない。
