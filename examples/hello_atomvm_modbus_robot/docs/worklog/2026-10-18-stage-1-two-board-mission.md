# Stage 1 two-board distributed mission — 2026-10-18

## 目的

2 台の XIAO ESP32-C5 上で genuine distributed Erlang を確立し、Controller が Drive の registered process へ
reference mission を送り、最終 rover state を検証する。

## 環境

- Host: Linux (Debian / LMDE)、timezone Asia/Tokyo
- Controller / Modbus Client: XIAO ESP32-C5、`/dev/ttyACM1`、USB serial `38:44:BE:A5:05:14`
- Drive / Modbus Server: XIAO ESP32-C5、`/dev/ttyACM0`、USB serial `38:44:BE:A5:04:DC`
- AtomVM: `v0.7.0-beta.0+git.8d3e051`
- 2 × HW-519、two-wire RS485、common signal ground
- UART1: TX GPIO23、RX GPIO24、9,600 baud、8N1
- Modbus Unit ID 1、custom Function Code 100
- FC-100 payload chunk: 96 bytes
- Client poll interval: 20 ms
- application timeout: 60,000 ms、retry: 1 回

Drive を先に起動し、registered process の準備完了を確認してから Controller を起動した。両 role の
`mix atomvm.check` は warning なしで成功し、flash 後の image hash verification も成功した。

| Role | 最終 PackBEAM size |
| --- | ---: |
| Controller | 213,424 bytes |
| Drive | 212,920 bytes |

## 結果

Drive は request ID 1–4 を順番にそれぞれ 1 回実行した。

```text
modbus_robot_drive: request_id=1 command={:forward, 100} result={:ok, %{y_mm: 0, x_mm: 100, heading_deg: 0, ...}}
modbus_robot_drive: request_id=2 command={:turn, :right, 90} result={:ok, %{y_mm: 0, x_mm: 100, heading_deg: 90, ...}}
modbus_robot_drive: request_id=3 command={:forward, 50} result={:ok, %{y_mm: 50, x_mm: 100, heading_deg: 90, ...}}
modbus_robot_drive: request_id=4 command=:status result={:ok, %{y_mm: 50, x_mm: 100, heading_deg: 90, ...}}
```

Controller は全 reply を受信し、reference mission の最終 state を確認した。

```text
modbus_robot_controller: received request_id=4 result={:ok, %{y_mm: 50, x_mm: 100, heading_deg: 90, ...}}
modbus_robot: reference mission returned {:ok, %{y_mm: 50, x_mm: 100, heading_deg: 90, ...}}
modbus_robot: mission complete state=%{y_mm: 50, x_mm: 100, heading_deg: 90, ...}
```

最初の command 送信から mission complete までの実測時間は約 7.9 秒だった。request ID 2–4 の各 command / reply
round trip は log timestamp 上で約 1.5 秒であり、最初の request は distribution の初期 traffic を含み約 3.4 秒だった。
この値は 1 回の観測値であり、性能保証や benchmark ではない。

## 観察

- application message は AtomVM の `net_kernel` / `serial_dist` と既存 FC-100 virtual UART を通過した。
- Controller だけが physical Modbus transaction を開始し、Drive の reply は Client poll response で返った。
- 96-byte chunk のため、serialized command と result は複数の FC-100 transaction に分割された。
- 正常系では application retry は発生せず、同じ movement command の重複実行もなかった。
- Drive が ready になる前に Controller を起動した別の試行では、最初の application timeout 後に distribution が回復した。
  ただしこれは in-flight command 中の reboot と durable recovery を検証するものではない。

## 結論と残課題

Stage 1 の基準 mission は、2 台の実機と genuine distributed Erlang を用いて完了した。Controller は remote registered
process を呼び出し、Drive が state transition を実行し、最終 state `(100, 50, 90°)` を返した。

request cache は RAM 上にしか存在しないため、Drive reboot をまたぐ exactly-once execution は保証しない。in-flight
command 中の peer reboot、state reconciliation、永続 command identity は fault-tolerance follow-up として残す。
