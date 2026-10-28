# 既知の制約

virtual robot application と3-node構成に固有の制約です。carrier 自体の制約は
[Modbus distributed Erlang example](../../hello_atomvm_modbus_disterl/docs/limitations.md)、実測値は
[検証結果](worklog/README.md) を参照してください。

## Topology

- `controller`、`drive`（Unit ID `1`）、`sensors`（Unit ID `2`）の固定3 role を対象とする
- Drive と Sensors は bus を駆動せず、Controller がすべての transaction と relay を直列化する
- 2本の logical stream は1つの UART と AVModbus Client を共有し、round-robin で poll する
- dynamic discovery、Server 間の直接通信、4 nodes 以上の application は実装していない
- 3-node distribution は AtomVM `18b35870` に local tick patch `a1069573` を加えた runtime で検証した

## Buffer と backpressure

- stream ごとの queue は既定 8,192 bytes / 256 chunks
- Controller 全体にも既定 8,192 bytes / 256 chunks の global budget がある
- 上限は carrier payload だけを数え、process、mailbox、binary、distribution framing は含まない
- queue-full は fail fast して該当 session を切り替える。queue 済み / in-flight data は破棄される
- peer 間の予約、公平な待機型 backpressure、collector crash 後の durable resume は提供しない
- host model の32 peers へ stream default を単純複製すると設定上限が 256 KiB になるため、同じ値を一般化しない

## Command と state

- Drive は直近32件の `{request_id, command, result}` を RAM に保持し、近接 retry の再実行を抑止する
- rover state、request cache、sensor sequence は reboot で失われる
- boot ID guard は別 boot での command 再実行を止めるが、旧 boot で実行済みかは確定しない
- request ID は永続 namespace ではなく、durable delivery や exactly-once execution を保証しない
- mission は `completed`、`aborted`、`indeterminate` を区別するが、自動 resume や state reconciliation は行わない

## Detection と recovery

- remote `Process.monitor/1` を利用できないため、readiness ACK と lease を使う
- heartbeat 30秒 / lease 75秒は即時検出ではなく、遅延時に false positive の可能性がある
- 初回 setup timeout と接続後障害は1回の restart budget を共有し、正常化後も同じ boot 中には補充しない
- transport reconnect は producer、mission、collector の再開を保証しない
- physical branch fault では round-robin polling により正常 peer を維持できたが、配線 topology に依存する
- current policy は非対称 response blackout から 2 / 2 復旧した一方、長時間 branch fault では 0 / 4 だった
- deferred policy は長時間 branch fault から 4 / 4 復旧した一方、非対称 blackout では 0 / 2 だった
- request 受理や Server 側 response return だけでは Controller への到達を証明できず、一般的な双方向 recovery signal は未実装
- `net_kernel.start/2` 成功後の setup timeout、minimum free heap 低下、過去の stop timeout の原因は公開 API だけでは特定できない

## Performance と用途

- half-duplex bus、polling、stop-and-wait、distribution framing により direct UART より遅い
- 115,200 baud の短時間 application soak でも remote RTT は平均約3.18秒
- 64 messages / role の無制御送信は queue を飽和させた。window 1 ACK では完走した
- 256 + 256 messages の完走と約1時間の endurance は単一 campaign であり、長期安定性の保証ではない
- fault injection は response drop だけを再現し、cable 断、partial frame、power loss と同一ではない
- physical actuator、real-time control、safety-critical control、production robot には使用しない

Recovery policy は failure model ごとに利点と欠点があります。どちらかを一般的な自動復旧保証として扱わず、
application は未確定状態を検出したら停止する設計を維持します。
