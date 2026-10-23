# 0006: 起動session IDでリモートノードの再起動を識別する

- Status: accepted
- Date: 2026-10-19

## 背景

Controller は Drive / Sensors からの readiness message を受け取り、初回接続と再接続を区別する必要がある。当初は送信元 PID が
変わった場合を再起動として扱った。しかし ESP32-C5 上の AtomVM を再起動すると application process の PID が再利用され、
Controller から reboot 前後の PID が同じ値に見える場合があった。この場合、正常に再接続しても readiness message を単なる
heartbeat と誤認する。

## 判断

- remote application は起動ごとに 32-bit の random boot session ID を生成する
- readiness message に role、node、PID と boot session ID を含める
- Controller は同じ role の PID と boot session ID が両方一致した場合だけ duplicate heartbeat とみなす
- node 名が role の固定 identity と一致しない message は引き続き拒否する
- 接続済み remote は 30 秒ごとに readiness heartbeat を送り、Controller の再起動後にも application registration を再確認できる

boot session ID には FC-100 carrier の session ID と同じ `DisterlProbe.Session` を使う。ただし両 ID の用途と lifecycle は独立である。

## 影響

- AtomVM が PID を再利用しても、remote reboot を検出して application probe を再実行できる。
- ID は durable identity ではなく、衝突確率を持つ volatile な識別子である。
- readiness heartbeat は追加の distribution traffic を発生させるため、5 秒間隔ではなく 30 秒間隔を既定値とする。
- Controller 自身の reboot 後も、再接続した両 remote が heartbeat で再登録し、application probe を完了することを実機確認した。
- 同じboard boot内でdistributionだけを再起動する場合はboot session IDを維持し、別のconnection IDを更新する。この追加判断は
  [ADR 0011](0011-restart-remote-distribution-after-ack-timeout.md)に記録する。
