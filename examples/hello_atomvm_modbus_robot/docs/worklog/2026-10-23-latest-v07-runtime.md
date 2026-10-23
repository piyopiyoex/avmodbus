# 最新 AtomVM v0.7 snapshot の3台実機検証 — 2026-10-23

## 目的

3-node robotで使っていたAtomVM runtimeを、2026-10-23時点の`release-0.7` snapshotへ更新する。
multi-connection tickのlocal compatibility patchを最新snapshotへ載せ直し、3台のXIAO ESP32-C5で
2本のdistribution connectionとsensor-driven missionが継続して動作するか確認する。

AtomVM upstreamへのIssueまたはPRは作成せず、必要な差分と結果はAVModbusの実験記録として管理する。

## Sourceとbuild条件

| 項目 | 値 |
| --- | --- |
| AtomVM baseline | `release-0.7` `18b35870` |
| local compatibility patch | `a1069573` (`Fix ticks with multiple distribution connections`) |
| ESP-IDF | v5.5.5 |
| target | ESP32-C5 |
| ESP-IDF configuration | `ATOMVM_RELEASE=on`、80 MHz、DIO、4 MB image header |
| boot library build | Erlang/OTP 27.3.4.16、Elixir 1.18.4-otp-27 |

生成物は次のとおりだった。

| Image | Size | SHA-256 |
| --- | ---: | --- |
| `atomvm-esp32.bin` | 1,722,736 bytes | `8a247dddbd1a2c87871a52e797fb86bf46c8ec12bc88ee8f95df134005f94253` |
| `elixir_esp32boot.avm` | 496,300 bytes | `4768ff25dbbe1eea259b639a29db4edbca10491af6c5f2ecdbd73d0a2baefefd` |

起動logではnative applicationが`v0.7.0-beta.0-19-ga1069573`、AtomVM revisionが
`0.7.0-beta.1+git.a1069573`と表示された。

ESP-IDF側はrelease configurationを使って再buildした。

```sh
source /path/to/esp-idf-v5.5.5/export.sh
idf.py -C /path/to/AtomVM/src/platforms/esp32 \
  -D ATOMVM_RELEASE=on set-target esp32c5
idf.py -C /path/to/AtomVM/src/platforms/esp32 build
```

plainなtarget configurationとrelease configurationではbootloaderが一致しなかった。今回のrelease buildで生成した
bootloaderは、事前に3-node試験で使っていた正常imageのbootloaderとbyte単位で一致した。最終更新では変更範囲を狭めるため、
bootloaderとpartition tableは既存のものを残した。

## 安全な更新手順

更新前に各boardの`0x0..0x24ffff`を読出し、SHA-256を記録した。これはbootloader、partition table、native runtime、
`boot.avm`を含み、`main.avm`の開始offset `0x250000`直前までである。

各boardでは次の2 partitionだけを更新した。

```text
0x010000  atomvm-esp32.bin
0x1d0000  elixir_esp32boot.avm
```

`main.avm`は書き換えていないため、Drive、Sensors、Controllerの既存robot firmwareとcompile-time profileを保持した。
Sensorsでnative runtimeだけ、続いてboot libraryを更新して段階的に確認した後、DriveとControllerへ同じ2 imageを適用した。

AtomVMのESP32-C5向けcomposite imageを使う場合、書込みoffsetは`0x0`ではなく`0x2000`である。今回の最終手順は曖昧さを
避けるためabsolute partition offsetを使った。

## Native USB monitorの注意

XIAO ESP32-C5のnative USB consoleを`/dev/ttyACM*`へ直接`tio`で開くと、reset時のUSB再列挙でmonitorが終了した。
この切断をruntimeのboot failureと誤認しないこと。検証には再列挙を待つExAtomVMのmonitor taskを使った。

```sh
mix atomvm.esp32.monitor --port /dev/serial/by-id/... --timeout 60
```

保存済みruntime領域を書き戻した後のreadbackは元のSHA-256と完全一致していた。専用monitorで確認すると正常に起動したため、
途中で観測したROM reset logだけを根拠にsnapshot buildの不具合とは判断しない。

## Hardware構成

| Role | USB serial | Modbus role |
| --- | --- | --- |
| Sensors | `10:BD:A3:CF:09:04` | Server、Unit 2 |
| Drive | `38:44:BE:A5:04:DC` | Server、Unit 1 |
| Controller | `38:44:BE:A5:05:14` | Client |

- 3 × Seeed Studio XIAO ESP32-C5
- 3 × HW-519
- breadboard railのcontinuous A/B trunk、node別branch、共通GND
- 115,200 baud、FC-100 chunk payload 96 bytes

## 結果

SensorsとDriveは更新後にそれぞれ正常起動し、Controllerからのreadiness ACKを受信した。Controller更新後は次を確認した。

1. DriveとSensorsのFC-100 peerを検出した。
2. `controller@modbus.local`から`drive@modbus.local`と`sensors@modbus.local`への2 connectionを確立した。
3. 両remoteからprobe replyを受信した。
4. sensor-driven missionを実行し、remote Driveへ4 requestを送った。
5. 最終state `{x_mm: 200, y_mm: 0, heading_deg: 90}`を確認した。

起動直後にDrive UnitへのModbus transaction timeoutを1回観測したが、retry後にconnectionとmissionは成功した。
mission完了後はControllerをresetせず90秒追加監視し、両streamのcarrier trafficが継続した。`net_kernel` crash、
distribution reconnect、session changeは観測しなかった。

## 結論

`release-0.7` `18b35870`とlocal tick patch `a1069573`からbuildしたnative runtimeとboot libraryは、3台の
XIAO ESP32-C5で動作した。2本のgenuine distributed Erlang connection、remote messaging、sensor-driven mission、
mission後90秒のconnection維持を確認した。

これはlocal compatibility patchを含む特定snapshotの実機baselineであり、公式AtomVM imageだけで3-node構成が動くこと、
長時間安定性、またはproduction readinessを示さない。次の`release-0.7`更新時は同じpatchの必要性と適用可否を再評価する。
