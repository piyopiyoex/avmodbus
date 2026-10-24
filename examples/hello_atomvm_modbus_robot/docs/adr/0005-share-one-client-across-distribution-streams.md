# 0005: 1個のModbus Clientを複数の分散接続ストリームで共有する

- Status: accepted
- Date: 2026-10-19

## 背景

AtomVM `serial_dist` は `uart_ports` option を受け取り、port ごとに link manager と byte stream を持てる。しかし、
Controller の 2 個の virtual UART adapter がそれぞれ `AVModbus.Client` を起動すると、同じ physical UART を複数 process が
開こうとする。さらに outgoing setup は接続先 node ではなく最初に応答した idle port を選ぶため、Controller から接続を
開始すると Modbus Unit ID と Erlang node の対応が曖昧になる。

## 判断

- Controller は physical UART を所有する `AVModbus.Client` を 1 個だけ起動する
- Drive Unit 1 と Sensors Unit 2 に対応する `DisterlProbe.ModbusUART` を 2 個起動する
- 各 adapter は sequence / ACK / session / queue / byte stream state を独立して持つ
- 両 adapter は外部所有の同じ managed Client を使い、FC-100 request を Client の FIFO queue で直列化する
- `serial_dist` には prepared adapter PID を `uart_ports` で渡す
- Drive と Sensors が Controller への logical connection を開始し、Unit ID と remote node の対応を固定する

このため `DisterlProbe.ModbusUART` には `client:` option を追加する。option を省略した既存 2-node mode では adapter 自身が
Client を所有する従来動作を維持し、外部 Client は adapter 終了時に stop しない。

## 影響

- physical UART と active Modbus transaction の owner は 1 process に保たれる。
- AVModbus core と AtomVM `serial_dist` の carrier interface は変更しない。
- 2 stream の polling により 9,600 baud の handshake は 7 秒 setup timer を超えた。実機 baseline は 115,200 baud とする。
- AtomVM `net_kernel` の複数 connection tick bug は別の runtime patch を必要とする。
- managed Client の queue は request を直列化するが、長時間 traffic に対する厳密な fairness はまだ保証しない。
