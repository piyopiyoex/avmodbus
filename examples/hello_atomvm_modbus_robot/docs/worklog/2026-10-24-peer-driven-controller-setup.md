# Peer-driven Controller transport setup — 2026-10-24

## 目的

4台目を検討する前段として、Controllerの2 peer transport setupからDrive / Sensors固有のadapter lifecycle重複を除く。
現在の3-node behaviorを変えず、host、AtomVM build、3台実機でregressionがないことを確認する。

設計判断は[ADR 0019](../adr/0019-drive-controller-transport-from-peer-descriptors.md)に記録した。

## 実装

`RobotSim.MultinodeDistributed.controller_peers/2`が、polling順に次のdescriptorを返す。

```elixir
[
  %{role: :drive, unit_id: 1, node: :"drive@modbus.local"},
  %{role: :sensors, unit_id: 2, node: :"sensors@modbus.local"}
]
```

Controllerはこのlistからadapterを順に生成し、PollScheduler登録、peer ready待ち、`serial_dist` port option、role別map、cleanupを構成する。
2個目以降のadapter生成に失敗した場合は、それまでに開いたadapterを閉じてからshared Clientとschedulerを停止する。

robot applicationのDrive / Sensors固有処理は変更していない。descriptor APIと既存`targets/2`の順序をhost testで照合した。

## AtomVM compatibility

最初の実装はadapter listからmapを作るため`Map.new/2`を使用した。host testは成功したが、Controllerの
`mix atomvm.check`がAtomVM 0.7.0-beta.0で未提供と警告した。実機flash前に`Enum.reduce/3`と`Map.put/3`へ置き換え、
Drive、Sensors、Controllerの3 roleでcompatibility warning 0とPackBEAM build成功を確認した。

## Firmware

| Role | Size | SHA-256 |
| --- | ---: | --- |
| Drive | 264,924 bytes | `e3768b6b58cebdaf3bf33dca790bad3af340e15794a6d1c587324bc201505dee` |
| Sensors | 264,896 bytes | `911d7ec147e91561339f9cde1557e90428c8ced6e7c059f6522a44feb7810727` |
| Controller | 270,460 bytes | `4b4128ae9f89f36b72e41dbd0ea413c61f15484928dd036bde97cb90aece6373` |

runtimeは前日と同じAtomVM `release-0.7` `18b35870` + local patch `a1069573`、ESP-IDF v5.5.5である。

## 実機結果

3 roleの`main.avm`だけを更新した。固定7秒setup timer内でfresh startするため、ControllerをROM download modeで停止し、Driveと
Sensorsを短い間隔でhard resetしてからControllerを起動した。

Controller logで次を確認した。

```text
modbus_robot_multinode: waiting for 2 FC-100 peers
modbus_robot_multinode: Controller distribution ready with 2 streams
modbus_robot_multinode: connected role=drive node=:drive@modbus.local
modbus_robot_multinode: connected role=sensors node=:sensors@modbus.local
```

両remoteのprobeに成功した。初期probe中にDrive Unitのtransaction timeoutを1回観測したが、retry後にmissionを継続した。
fresh rover stateから`forward 100`、`forward 100`、`right 90°`を実行し、最終stateは
`{x_mm: 200, y_mm: 0, heading_deg: 90}`だった。

## 結論

Controllerのtransport setupをpeer descriptor list駆動へ変更しても、既存2 streamとrobot missionは3台実機で動作した。
これは4-node distributionの実証ではない。次は第4 roleのapplication境界を定義し、4台目を用意した後にUnit 3のstandard Modbus、
続いて3本目のdistribution connectionを段階的に検証する。
