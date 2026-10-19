# Stage 3 three-node distributed Erlang — 2026-10-19

## 目的

Stage 2 で確認した shared RS485 bus 上に Unit ごとの FC-100 byte stream を作り、Controller から Drive と Sensors の 2 node を
同時に genuine distributed Erlang connection として維持できるか確認する。

## 構成

hardware、port、USB serial、GPIO は
[Stage 2 worklog](2026-10-19-stage-2-multidrop.md) と同じである。主な差分は次のとおり。

- application mode: `ROBOT_MODE=multinode`
- UART speed: 115,200 baud
- Controller: 1 個の shared `AVModbus.Client` と 2 個の `DisterlProbe.ModbusUART`
- Drive: Server Unit 1、node `drive@modbus.local`
- Sensors: Server Unit 2、node `sensors@modbus.local`
- Controller: node `controller@modbus.local`、`serial_dist` の `uart_ports` に 2 stream を指定
- operating chunk: 96 bytes、poll interval: 20 ms

Controller の PackBEAM は 220,996 bytes、Drive は 218,788 bytes、Sensors は 218,564 bytes だった。3 台とも flash 後の
hash verification に成功した。

## 9,600 baud の negative result

Unit ごとの session、handshake bytes、response は両 stream で観測できたが、2 connection を shared Client で poll すると各
handshake が AtomVM の固定 7 秒 setup timer に収まらなかった。Controller、Drive、Sensors の各側で `timer_timeout` を記録し、
remote application message には到達しなかった。

この結果から Stage 3 の実機 baseline を 115,200 baud へ変更した。これはすべての配線や transceiver に対する一般的な推奨値
ではなく、今回の hardware profile で handshake を成立させる条件である。

## 115,200 baud の初回成功と AtomVM blocker

115,200 baud では両 node の handshake と remote probe が成功した。

```text
modbus_robot_multinode: probe reply role=drive node=:drive@modbus.local
modbus_robot_multinode: probe reply role=sensors node=:sensors@modbus.local
modbus_robot_multinode: complete Drive and Sensors remote messaging
```

しかし最初の distribution tick で Controller の `net_kernel` が `function_clause` で crash した。AtomVM `net_kernel` の tick
処理は `maps:fold/3` の accumulator を `ok` に限定している一方、alive connection への
`ConnPid ! {self(), tick}` は送信 message 自体を返す。connection が 1 個なら fold が終了するため問題にならないが、2 個目で
accumulator が `ok` ではなくなり function clause に一致しない。

## AtomVM local patch

既存の setup PID cleanup branch `fix/net-kernel-setup-pid` に、send 後 `ok` を明示する最小修正と 2 connection の regression test を
追加した。

```erlang
{alive, ConnPid, _Address} ->
    ConnPid ! {self(), tick},
    ok;
```

- base: AtomVM `4ef13692`
- setup retry patch: `735841ba`
- local tick patch: `74840ccc6f27ee060209de7c05ffc96204249d48`
- isolated AtomVM regression test: `Return value: ok`
- `elixir_esp32boot.avm`: 500,056 bytes
- SHA-256: `41f3e79bc35f65b78347ee15dac37459eb658f34d13de58e8d91059c3d6c7189`

書き換え前に 3 台の 512 KiB boot partition を `/tmp` へ保存した。Controller / Drive は同じ patched image、Sensors は公式 image
だった。保存 image の SHA-256 はそれぞれ次のとおり。

| Device | SHA-256 |
| --- | --- |
| Controller / Drive | `ab0c4bfedca2bfed7631f6df75bc21be864333ea0e5eca4244d7f86134f75461` |
| Sensors | `f73700afb5832abef635682ea5151c3a52bc7981efa835e602e6fe83ab488fdb` |

tick patch はこの AVModbus repository や公式 AtomVM release にはまだ含まれない。

## 最終 run

Controller を先に起動し、Drive、Sensors の順に reset した。Controller distribution ready から約 9.7 秒で Drive、約 10.8 秒で
Sensors を認識した。両方を認識してから順番に registered process へ probe を送り、約 14.8 秒で 2 reply を完了した。

```text
modbus_robot_multinode: Controller distribution ready with 2 streams
modbus_robot_multinode: connected role=drive node=:drive@modbus.local
modbus_robot_multinode: connected role=sensors node=:sensors@modbus.local
modbus_robot_multinode: both remote nodes connected
modbus_robot_multinode: probe reply role=drive node=:drive@modbus.local
modbus_robot_multinode: probe reply role=sensors node=:sensors@modbus.local
modbus_robot_multinode: complete Drive and Sensors remote messaging
```

完了後も含めて Controller console を reset から 90 秒間監視した。複数の 15 秒 tick interval をまたぎ、`net_kernel` crash、
distribution timeout、再接続は記録されなかった。

## 結論と残る作業

1 本の Modbus RTU UART 上で 2 個の FC-100 stream を多重化し、Controller と 2 remote node の genuine distributed Erlang を
同時に成立させられた。専用 `modbus_dist` carrier はこの基本疎通には不要だった。

一方、現在の結果は local AtomVM patch と 115,200 baud を必要とする experimental baseline である。remote node の独立 reboot、
一方の timeout が他方へ与える影響、継続 application traffic、Drive / Sensors 間 relay、長時間 fairness は未検証である。
