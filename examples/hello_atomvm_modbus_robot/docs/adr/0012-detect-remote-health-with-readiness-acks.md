# 0012: readiness ACKでリモート分散接続の健全性を判定する

## 状態

採用

## 背景

ADR 0011 では concurrent traffic の application ACK timeout を契機に、1 connection だけを持つ remote の
`net_kernel` を再起動した。しかし idle な connection には application ACK が存在しない。さらに、Controller の readiness lease は
Controller 側から見た remote availability を判定するものであり、非対称 response blackout で stale connection を保持する
remote 自身の判断には使えない。

常時 application traffic を生成せずに half-open connection を検出し、誤判定による無限 restart を防ぐ仕組みが必要である。

## 判断

Drive / Sensors は既存の readiness heartbeat を connection-scoped health probe として再利用する。

- readiness に含まれる distribution connection ID を Controller の ACK にも含める
- remote は現在の connection ID と一致する ACK だけを health 更新に使う
- heartbeat は application mailbox traffic によって延期されない timer message で起動する
- ACK が設定期限を超えて届かなければ remote 側の `net_kernel` 全体を stop / restart する
- restart 回数は board boot ごとに設定上限を持ち、上限到達は連続 outage 中に1回だけ記録する
- `net_kernel.stop/0` の返却後も旧 process が残る場合があるため、登録解除を bounded poll してから start する
- 機能は opt-in とし、既定では無効にする

Controller の readiness lease は残す。Controller 側の availability と remote 側の connection health は目的が異なるため、同じ状態機械へ
統合しない。

## 影響

application traffic がない状態でも、remote は ACK を返せない非対称 connection を検出できる。connection generation が変わった後に届く
古い ACK は無視され、restart storm は boot 単位の上限で抑制される。

一方、Drive / Sensors が持つ distribution connection は現在1本だけなので、回復処理は `net_kernel` 全体を再起動する。複数 peer を持つ
Controller へそのまま適用しない。timeout は failure の証明ではなく、bus congestion や長い scheduler delay による false positive の可能性が
あるため、heartbeat 間隔より十分長く設定する。

この判断は durable workload recovery、個別 peer disconnect、mission state reconciliation を提供しない。AVModbus core、FC-100 wire protocol、
AtomVM runtime は変更しない。
