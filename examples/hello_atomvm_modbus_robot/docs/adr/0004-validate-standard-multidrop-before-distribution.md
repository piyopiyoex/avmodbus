# 0004: 3-node distribution より先に standard multidrop を検証する

- Status: accepted
- Date: 2026-10-19

## 背景

3 台の distributed Erlang には、shared UART の ownership、複数の FC-100 session、poll scheduling、複数の
`serial_dist` connection という独立した問題がある。physical RS485 multidrop と distribution carrier を同時に変更すると、
failure の原因を分離できない。

## 判断

Stage 2 は `ROBOT_MODE=multidrop` という独立 mode にする。この mode では `net_kernel`、`serial_dist`、FC-100 を開始せず、
AVModbus の standard RTU Client / Server API だけを使う。

- Controller だけが 1 本の UART を所有し、Drive Unit 1、Sensors Unit 2 を必ず順番に poll する
- 両 Server は同じ bus を受信するが、自分の Unit ID にだけ応答する
- Function Code 3 で 2 個の identity register を読み、response の role と Unit ID を検証する
- 1 unit の timeout で probe 全体を停止せず、もう一方も poll して per-role success / failure を集計する

## 影響

- standard Modbus multidrop の問題を 3-node distribution から分離できる。
- Client process による直列 request 処理が physical bus arbitration になる。
- identity register は Stage 2 probe 専用であり、virtual sensor model ではない。
- Stage 3 はこの結果を前提にできるが、複数 virtual UART stream や distribution connection は別途設計が必要である。
- `ROBOT_MODE=distributed` の既存 2-node mission と AVModbus core は変更しない。
