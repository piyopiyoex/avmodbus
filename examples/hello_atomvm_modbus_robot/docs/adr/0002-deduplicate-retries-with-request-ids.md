# 0002: request ID で command retry を重複排除する

- Status: accepted
- Date: 2026-10-18

## 背景

Controller が movement command を送った後に reply だけを失うと、command が実行済みか判断できません。同じ
movement を単純に再送すると、rover が二重に移動する可能性があります。Modbus carrier の sequence / ACK は byte stream
の配送を扱いますが、application command が実行されたかどうかまでは保証しません。

## 判断

application request を `{:robot_command, reply_to, request_id, command}`、reply を
`{:robot_reply, request_id, result}` とします。timeout retry は同じ `request_id` と command を再利用します。

Drive process は default で直近 32 件の `{request_id, command, result}` を memory に保持します。同じ ID と command を
受信した場合は state transition を再実行せず、保存した result を返します。同じ ID で異なる command を受信した場合は
`{:error, :request_id_conflict}` を返します。cache は件数で制限します。

## 影響

- lost reply 後の近接した retry で movement を重複実行しません。
- application protocol は Modbus carrier と独立して host 上で test できます。
- Drive reboot または cache eviction 後には履歴が残らず、durable exactly-once は保証しません。
- 同じ Drive process で新しい mission を開始する場合、Controller は以前と重ならない request ID を使う必要があります。
- Controller reboot、request ID の namespace、mission reconciliation は実機 Stage 1 と Stage 4 で追加検討します。

Stage 1 の実機試験では、request 2 の実行後、reply 前に Drive を reset しました。transport / distribution は再接続し、
Controller の retry も届きましたが、Drive の rover state と cache は reboot で失われました。この結果は上記の境界と一致します。
詳細は [in-flight Drive reboot の作業記録](../worklog/2026-10-18-stage-1-drive-reboot.md) にあります。
