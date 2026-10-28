# ロードマップ

この example は、Modbus RTU 上で genuine distributed Erlang を動かす当初の目標を達成しました。
今後は機能を増やすのではなく、2-node experimental baseline の再現性を維持します。

## 現在地

| 領域 | 状態 |
| --- | --- |
| FC-100 logical transport | 双方向配送、順序、ACK、再送、重複抑止を確認済み |
| Genuine distribution | handshake、remote messaging、multi-chunk payload を確認済み |
| Recovery | 起動順序、独立 reboot、active-transfer reboot を確認済み |
| Resource protection | 8 KiB / 256 chunks、queue-full rollover、idle marker coalescing |
| Package boundary | AVModbus core へ移さず example 内に維持 |

実測条件と代表値は [検証結果](worklog/README.md)、保証外の範囲は
[既知の制約](limitations.md) を正とします。

## Follow-up の着手条件

- AtomVM `release-0.7` の distribution lifecycle が変わった場合に setup retry を再検証する
- memory stability を評価する場合は、数時間の soak と反復 fault run の停止条件を先に決める
- 115,200 baud や sequence wraparound を一般化する場合は、複数 run の実機結果を追加する
- 独立した consumer と stable lifecycle contract が得られた場合だけ companion package を検討する

3-node application、shared-client scheduling、長時間通信断は
[仮想ロボット example](../../hello_atomvm_modbus_robot/docs/roadmap.md) で扱います。

## 維持する境界

- production-ready transport、dynamic discovery、routing は対象外
- dedicated `modbus_dist` carrier は、virtual UART で不足する根拠が得られるまで実装しない
- 実験固有の要件を理由に AVModbus core を変更しない
- performance optimization は再現可能な測定結果に基づいて行う
