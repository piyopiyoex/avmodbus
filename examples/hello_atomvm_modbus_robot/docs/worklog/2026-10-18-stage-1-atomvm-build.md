# Stage 1 AtomVMビルド基盤 — 2026-10-18

## 目的

既存 FC-100 virtual UART を source copy なしで再利用し、Controller / Drive 両 role の AtomVM application が
PackBEAM artifact まで生成できることを host 上で確認する。

## 構成

- local path dependency: `../hello_atomvm_modbus_disterl`
- AtomVM start module: `RobotSim.Distributed`
- Controller node: `controller@modbus.local` / Modbus Client
- Drive node: `drive@modbus.local` / Modbus Server Unit ID 1
- virtual UART: `DisterlProbe.ModbusUART`
- application destination: registered process `:modbus_robot_drive`

## 互換性の追試

最初の `mix atomvm.check` は、host simulation で使っていた次の function が AtomVM 0.7.0-beta.0 にないと報告した。

- `Enum.reduce_while/3`
- `Enum.take/2`
- `Enum.with_index/2`

これらを小さな recursive function に置き換え、robot project に `atomvm` と `exatomvm` を direct dependency として
追加した。

## 実行

```sh
for role in controller drive; do
  mix clean
  ROBOT_ROLE="$role" MIX_ENV=prod mix atomvm.check
  ROBOT_ROLE="$role" MIX_ENV=prod mix atomvm.packbeam
done
```

## 結果

| Role | `atomvm.check` | PackBEAM size |
| --- | --- | ---: |
| Controller | warning なし | 212,272 bytes |
| Drive | warning なし | 211,768 bytes |

`No avm_deps directory found` という informational message は表示された。standard library は AtomVM の lib partition に
書き込み済みであることを前提とするため、既存 example と同様に許容する。

## 残る範囲

この記録は build artifact の生成までであり、UART open、FC-100 peer readiness、distribution handshake、remote mission は
まだ実機確認していない。次は 2 台の XIAO ESP32-C5 に Drive / Controller を書き込み、最終 state と log を記録する。
