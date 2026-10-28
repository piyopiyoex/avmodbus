# 検証結果

Stage 0〜11 の代表的な結果をまとめます。個別の console log と操作時刻は Git の履歴、
現在の実行方法は [サンプル README](../../README.md)、設計判断は [ADR](../adr/README.md) を参照してください。

## 実機 baseline

| Role | USB serial | Modbus role |
| --- | --- | --- |
| Controller | `38:44:BE:A5:05:14` | Client |
| Drive | `38:44:BE:A5:04:DC` | Server、Unit ID `1` |
| Sensors | `10:BD:A3:CF:09:04` | Server、Unit ID `2` |

- Device: Seeed Studio XIAO ESP32-C5 × 3、HW-519 × 3、shared 2-wire RS485
- Runtime: AtomVM `release-0.7` `18b35870` + local tick patch `a1069573`
- Multinode profile: 115,200 baud、20 ms poll、96-byte chunk
- 検証期間: 2026-10-18〜28

## Application milestone

| Stage | 主な結果 |
| ---: | --- |
| 0 | reference mission が `{x_mm: 100, y_mm: 50, heading_deg: 90}` で完了 |
| 1 | 2-node genuine distribution mission、same-ID retry、Drive reboot 後の state 不一致検出 |
| 2 | 3-device standard Modbus、60 cycles / 120 requests、error 0、各 Server reboot から復帰 |
| 3 | Controller から Drive / Sensors の2 connection、remote messaging、relay、独立 reboot |
| 4 | sensor-driven mission、readiness lease、reply-loss retry、Drive boot guard |
| 5 | 1 / 2 / 3 / 8 / 32 peers の host model で round-robin fairness と single active transaction |
| 6 | 全6起動順序、bounded initial recovery、global queue budget、endurance |
| 7〜9 | 長時間 branch fault と非対称 response blackout で recovery policy を比較 |
| 10 | `net_kernel` lifecycle と distribution setup failure を分離 |
| 11 | Sensors fault で mission を停止し、復旧後に非変更 status を取得 |

## Traffic と endurance

| Scenario | 結果 |
| --- | --- |
| 64 + 64、window 1 ACK | 128 / 128、欠損・重複なし、163.039 s |
| 256 + 256 campaign A | 512 / 512、627.792 s、queue high-water 279 / 162 bytes |
| 256 + 256 campaign B | 512 / 512、783.317 s、minimum Controller heap 68,848 bytes |
| 64分30秒 active / idle | 12 / 12 runs、Drive / Sensors 各192 messages、restart 0、global rejection 0 |

endurance では periodic free heap の単調減少を観測しませんでした。Sensors の retry 可能な transaction
timeout は8件あり、error-free transport や数日間の安定性を示す結果ではありません。

## Startup と resource budget

- 3 role の全6起動順序で、両 remote は約4.5〜7.2秒で接続
- 初回 setup timeout 後の bounded remote restart により、board reset なしで対象 peer が復旧
- Controller global budget は ACK、session reset、adapter stop で解放されることを host test で確認
- 3台 campaign では global rejection 0、queue は停止条件までに drain
- 32-peer host model の configured payload 合計 262,144 bytes は実機 minimum heap より大きく、default の単純複製は不可

## Long outage recovery

Sensors branch だけを外し、Drive を維持して比較しました。

| Failure model | Current | Deferred |
| --- | --- | --- |
| 120 / 300秒 branch fault、各4 runs | 0 / 4 | 4 / 4 |
| 約83秒の response blackout、各2 runs | 2 / 2 | 0 / 2 |

Deferred policy の branch fault では、観測した FC-100 gap 166.510〜393.908秒の後、transport ready から
10.690〜12.119秒で Sensors / Drive 両 probe が成功しました。Current は transport 復帰前に restart budget を
消費しました。一方、request を受理し続ける非対称 blackout では deferred policy が復帰を検出できませんでした。
4 runs すべてで Drive connection は維持されました。

この結果から current を既定、deferred を opt-in のまま維持しています。

## Runtime lifecycle

- Healthy `net_kernel` stop / start は登録解除 88 ms、再開まで合計 204 msで完了
- branch 切断中の60秒 / 120秒 probe では stop は67 msで完了したが、再開後の distribution setup が timeout
- 過去に観測した `net_kernel_stop_timeout` は再現せず、発生条件を一般化できなかった
- setup failure 中の minimum free heap 低下は process 数と owner mailbox だけでは説明できなかった

AtomVM 内部 resource の原因は特定せず、この repository では再現条件と application 側の責任境界だけを記録します。

## Application recovery

Sensors branch を mission step 1 後に切断した scenario では、step 2 の sample timeout を
`aborted / stop` として扱いました。Drive connection を維持し、Sensors 復旧後に fresh sample と guarded status を
取得しました。Drive state は `{x_mm: 100, y_mm: 0, heading_deg: 0}` のままで、movement の再実行や
mission の自動 resume は発生しませんでした。

## 判断

- 3台を physical baseline とし、scale は host model を先に使う
- transport、distribution、application recovery の成功を別々に判定する
- application command の結果が未確定なら自動再実行せず停止する
- durable state と automatic resume は実装しない

残る保証外の範囲は [既知の制約](../limitations.md)、次の着手条件は [ロードマップ](../roadmap.md) を参照してください。
