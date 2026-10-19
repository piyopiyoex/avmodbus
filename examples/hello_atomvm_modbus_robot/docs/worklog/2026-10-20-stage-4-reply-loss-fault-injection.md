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

## 実機検証の残作業

この時点では3台の USB serial device がホストに現れておらず、flash と RS485 実行は未実施である。実機では次を確認する。

- Drive log が各 request ID について `injected reply loss` を1回だけ出す
- Controller log が同じ request ID を attempt 2 で再送する
- retry reply が cache 済み result から返る
- 3-step adaptive mission の final state が `(x=200, y=0, heading=90°)` になる
- Drive の movement が reply loss によって二重実行されない

## 保証しない範囲

- Drive reboot 後は rover state と request cache が失われる
- cache eviction 後に古い request ID を再利用すると再実行される
- fault injection は application reply loss を再現するもので、physical RS485 outage や distribution reconnect を再現しない
- durable exactly-once execution は提供しない
