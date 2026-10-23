# 0007: Server間のアプリケーションメッセージはControllerで中継する

- Status: accepted
- Date: 2026-10-19

## 背景

Drive と Sensors は Modbus RTU Server であり、自分から physical bus transaction を開始できない。Stage 3 の Controller は 1 個の
Modbus Client を所有し、Drive と Sensors へ独立した distributed Erlang connection を確立している。virtual sensor data を Drive
へ届けるために、Server 間の直接 connection、transport layer の routing、または Controller process による application relay の
どれを採用するか決める必要がある。

## 判断

- Sensors と Drive の間に直接の distribution connection は作らない
- Controller が Sensors の registered process へ sample を要求し、妥当性を確認してから Drive の registered process へ転送する
- Drive は sample を保存し、Controller へ明示的な ACK または reject を返す
- virtual sensor、relay、Drive の責務を application module に置き、FC-100 carrier と AVModbus core は変更しない
- host test と実機で同じ application message を使い、宛先だけを local PID から `{registered_name, node}` に変える

message path は次のとおりである。

```text
Sensors Server --distribution--> Controller Client --distribution--> Drive Server
```

physical bus 上では両区間とも Controller の Modbus Client が poll する。Server node が bus を直接駆動することはない。

## 影響

- standard Modbus RTU の client/server 制約を保ったまま、3 node にまたがる application data flow を構成できる。
- transport に application routing を追加せず、simulation logic を host 上で単体試験できる。
- 1 回の relay に Sensors request/reply と Drive forward/ACK の 2 区間が必要なため、latency は加算される。
- Controller は routing と bus ownership の single point of coordination になる。
- sensor sequence と Drive の last sample は volatile であり、reboot をまたぐ durable delivery や exactly-once semantics は提供しない。
