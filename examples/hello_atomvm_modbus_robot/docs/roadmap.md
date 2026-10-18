# ロードマップ

この example は、host-only simulation から 2-node distributed application、3-device Modbus multidrop、
3-node distribution の調査へ段階的に進めます。各 Stage は前段の完了を前提としますが、Stage 3 の成功は
仮定しません。技術的 blocker を特定して記録することも成果とします。

現在の実行方法は [サンプル README](../README.md)、設計判断は [ADR](adr/README.md)、実測結果は
[作業記録](worklog/README.md) を正とします。

## 現在地

| Stage | 状態 | 範囲 |
| --- | --- | --- |
| 0 | 完了 | host-only virtual rover |
| 1 | 未着手 | 2-node distributed robot |
| 2 | 未着手 | 3-device standard Modbus multidrop |
| 3 | research | 3-node distributed Erlang |
| 4 | 未着手 | virtual sensors と fault tolerance |

## Stage 0: local virtual rover simulation

- [x] 独立した Mix example project を追加する
- [x] position と heading を持つ virtual rover を pure function で実装する
- [x] forward、left / right turn、status command を実装する
- [x] 座標と heading の規則を明示する
- [x] deterministic demonstration mission を追加する
- [x] host-side unit test を追加する
- [x] host 上で format、test、reference mission を実行する
- [x] 日本語の利用手順、ADR、worklog を追加する
- [x] repository CI で example の format と test を実行する

完了条件は、host test が成功し、reference mission が
`{x_mm: 100, y_mm: 50, heading_deg: 90}` で終了することです。

## Stage 1: two-node distributed robot

- [ ] 既存 FC-100 / virtual UART carrier の再利用境界を決める
- [ ] `controller@modbus.local` と `drive@modbus.local` を構成する
- [ ] controller を board A、virtual rover process を board B で起動する
- [ ] command ID、明示的な reply、timeout を持つ小さな application protocol を定義する
- [ ] remote registered process へ movement command を送る
- [ ] drive node で state transition を実行し、result と status を返す
- [ ] reference mission の最終座標を controller 側で検証する
- [ ] in-flight command 中の peer reboot を試し、重複実行の扱いを記録する
- [ ] 2 台の XIAO ESP32-C5 による実機結果を worklog に記録する

完了条件は、genuine distributed Erlang の message path で 2 台の実機が mission を完了し、controller が
最終 state を検証することです。

## Stage 2: three-device Modbus multidrop

この Stage では Erlang distribution を使わず、standard Modbus RTU の multidrop を先に検証します。

- [ ] 3 台目の XIAO ESP32-C5 と HW-519 を shared two-wire bus へ接続する
- [ ] drive を Unit ID 1、sensors を Unit ID 2 にする
- [ ] controller の single UART から両方の Server を順番に poll する
- [ ] transaction が重ならない bus scheduling と UART ownership を確認する
- [ ] termination / bias、fairness、latency、timeout、error behavior を記録する
- [ ] 各 Server を独立に reboot して recovery を確認する

完了条件は、1 台の Client が 2 台の Server と同じ RS485 bus 上で安定して standard Modbus 通信できることです。

## Stage 3: three-node distributed Erlang

- [ ] drive と sensors に独立した sequence / ACK / session / byte-stream state を設計する
- [ ] 1 本の physical UART を所有する process と公平な polling policy を設計する
- [ ] 複数の virtual UART stream を `serial_dist` / `net_kernel` に渡す方法を調査する
- [ ] `controller <-> drive` と `controller <-> sensors` の connection を確立する
- [ ] 両 remote node の registered process と message を交換する
- [ ] Server node 間の message を controller で relay する必要があるか検証する
- [ ] 片方の Server reboot がもう一方の connection に与える影響を確認する
- [ ] dedicated carrier または別の transport abstraction が必要か判断する

完了条件は、controller と 2 台の remote node の genuine distribution を実証するか、必要な AtomVM / carrier
変更と blocker を再現可能な形で記録することです。Modbus Server 同士が bus を直接駆動する構成は仮定しません。

## Stage 4: virtual sensors と fault tolerance

- [ ] virtual distance / obstacle sensor を追加する
- [ ] simulated battery status を追加する
- [ ] sensor data に基づいて controller が mission を変更する
- [ ] process monitoring と independent node restart を検証する
- [ ] mission 中の communication interruption を検証する
- [ ] retried movement command の重複実行を防ぐ
- [ ] bounded queue、recovery behavior、残る制約を記録する

## 今回は対象としないこと

- physical robot、motor、実 sensor の製作と driver
- real-time motion control と safety-critical control
- production-ready robotics software
- dynamic node discovery
- AVModbus core の general-purpose multidrop distribution support
- 機能検証より先に行う performance optimization
