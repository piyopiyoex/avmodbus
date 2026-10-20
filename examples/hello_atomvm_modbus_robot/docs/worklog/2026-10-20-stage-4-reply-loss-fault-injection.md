# Stage 4 reply loss fault injection — 2026-10-20

## 目的

movement command の実行後に application reply だけを失った場合、Controller が同じ request ID で retry し、Drive が rover の
state transition を重複実行せず cache 済み result を返せるか検証する。transport timeout や node reboot と切り分けるため、最初は
Drive application process 内の opt-in fault injection を使用する。

## 実装

`ROBOT_DRIVE_DROP_FIRST_REPLY_PER_REQUEST=true` で build した Drive は、未処理の request ID を初めて実行した直後の reply を
破棄する。実行結果と command は通常どおり bounded cache に保存する。同じ request ID と command の retry は cached result を返し、
state transition を再実行しない。

この設定は既定で `false` であり、通常の example 動作には影響しない。各 request の最初の reply を破棄するため、movement だけでなく
mission 終了時の status request も retry path を通る。

## Host 検証

既存の proxy による lost-reply test に加えて、Drive 自身の fault injection を有効にした test を追加した。

```text
mix format --check-formatted
mix test
mix atomvm.check

46 tests, 0 failures
```

test では100 mm前進 command の初回 reply を破棄し、Controller の retry が成功した後も Drive state が `x_mm=100` のままであることを
確認した。

## Production build

3 role すべてで AtomVM compatibility check と PackBEAM build に成功した。Controller の試験 profile は command timeout 20秒、
retry 1回である。

| Role | Build profile | PackBEAM size |
| --- | --- | ---: |
| Drive | reply loss injection 有効 | 233,144 bytes |
| Sensors | 通常 | 233,116 bytes |
| Controller | timeout 20秒、retry 1回 | 237,020 bytes |

## 3台実機検証

一時的に USB serial device がホストから見えず保留した後、3台すべての接続を再確認して同じ build を flash した。

| Role | Unit ID | Port | USB serial |
| --- | ---: | --- | --- |
| Drive | 1 | `/dev/ttyACM0` | `38:44:BE:A5:04:DC` |
| Sensors | 2 | `/dev/ttyACM1` | `10:BD:A3:CF:09:04` |
| Controller | Client | `/dev/ttyACM2` | `38:44:BE:A5:05:14` |

- 3 × Seeed Studio XIAO ESP32-C5
- shared two-wire RS485 bus、115,200 baud
- FC-100 chunk payload 96 bytes
- Controller command timeout 20秒、retry 1回
- Drive reply loss injection 有効

Controller は4つの request すべてで attempt 1 を timeout とし、同じ request ID の attempt 2 を送った。Drive は対応する各 ID で
`injected reply loss` を正確に1回だけ記録した。

| Request ID | Command | Attempt 2 result |
| ---: | --- | --- |
| `831330251` | `{:forward, 100}` | `x=100, y=0, heading=0°` |
| `831330252` | `{:forward, 100}` | `x=200, y=0, heading=0°` |
| `831330253` | `{:turn, :right, 90}` | `x=200, y=0, heading=90°` |
| `831330254` | `:status` | `x=200, y=0, heading=90°` |

代表的な Controller log は次のとおりである。

```text
modbus_robot_controller: request_id=831330251 timed out; retrying
modbus_robot_controller: sending request_id=831330251 attempt=2 command={:forward, 100}
modbus_robot_controller: received request_id=831330251 result={:ok, %{x_mm: 100, ...}}
...
modbus_robot_multinode: sensor mission complete state=%{x_mm: 200, y_mm: 0, heading_deg: 90, ...}
modbus_robot_multinode: complete Drive and Sensors remote messaging
```

Drive は各 command の初回実行で次を出力し、same-ID retry では再度出力しなかった。

```text
modbus_robot_drive: injected reply loss request_id=831330251
modbus_robot_drive: injected reply loss request_id=831330252
modbus_robot_drive: injected reply loss request_id=831330253
modbus_robot_drive: injected reply loss request_id=831330254
```

2回の forward と1回の right turn の最終状態が `(x=200, y=0, heading=90°)` であるため、reply loss 後の retry で movement は
重複実行されていない。mission 完了後も両 stream の polling は継続した。

Drive log には Controller flash による peer session change 時に古い `serial_dist_controller` reader の
`{serial_read_error, closed}` crash report が出た。新しい connection はその後確立し、今回の retry と mission は完了した。

試験後は Drive を injection 無効の通常 build、Controller を default 60秒 timeout の通常 build に戻し、hash verification を完了した。
Sensors、Drive、Controller の順に reset して volatile state も初期化した。復元後の mission では4 request すべてが attempt 1 で成功し、
final state `(x=200, y=0, heading=90°)` を再確認した。

## 保証しない範囲

- Drive reboot 後は rover state と request cache が失われる
- cache eviction 後に古い request ID を再利用すると再実行される
- fault injection は application reply loss を再現するもので、physical RS485 outage や distribution reconnect を再現しない
- durable exactly-once execution は提供しない

## 結論

reboot を伴わない application reply loss では、bounded request cache と same-ID retry により genuine 3-node distribution path 上でも
movement の重複実行を防げた。physical RS485 interruption と reboot をまたぐ mission reconciliation は別の failure modelとして残る。
