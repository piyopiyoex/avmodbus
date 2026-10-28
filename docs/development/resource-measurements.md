# リソース計測

AtomVM application の artifact size と実機 memory を、同じ条件で比較するための基準値です。
瞬間的な peak や、別の基板・runtime に対する保証ではありません。

## Artifact size

対象は pinned toolchain と既定設定で build した
`examples/hello_atomvm_modbus/sample_app.avm` です。memory・health・resource probe を有効にした
diagnostic build は対象外です。

| 項目 | 値 |
| --- | ---: |
| 基準値 | 147,536 bytes |
| 上限 | 147,736 bytes |
| 余裕 | 200 bytes |
| SHA-256 | `7a995704650c1bd5e7830d6b51c010a0a05b0ecd8644a32cbb4652a59aa39e8a` |

```sh
cd examples/hello_atomvm_modbus
MIX_ENV=prod mix atomvm.size
```

上限を変更するときは、増加理由、互換性 check、host test、実機 smoke test を記録します。

## RTU role の memory

2026-10-12 に XIAO ESP32-C5、AtomVM `v0.7.0-beta.0`、RTU 9,600 baud、UART1、
GPIO23 TX / GPIO24 RX で計測しました。role 起動前後に GC を実行し、起動後 100 ms 待ってから
ESP32 heap と managed process の `process_info/2` を取得しています。

| Role | Free heap（前 → 後） | Process 数 | Managed process memory |
| --- | ---: | ---: | --- |
| Client | 179,656 → 153,952 B | 3 → 7 | client: 824 B |
| Server | 179,528 → 144,328 B | 3 → 8 | memory: 560 B、server: 1,204 B |

差分には module load、UART resource、driver state も含みます。managed process 単体の費用ではありません。

計測する場合は role ごとに clean build します。

```sh
cd examples/hello_atomvm_modbus
MIX_ENV=prod mix clean
MODBUS_MEASURE_MEMORY=true MIX_ENV=prod mix atomvm.packbeam
MODBUS_MEASURE_MEMORY=true MIX_ENV=prod \
  mix atomvm.esp32.flash --port /dev/ttyACM_CLIENT
```

Server では build と flash の両方へ `MODBUS_ROLE=server` を追加します。

## TCP loopback

2026-10-13〜14 に official AtomVM `v0.7.0-beta.0` 上で network stack を warm-up してから、
1〜4 connections を各3 cycles 計測しました。値は listener、managed Clients、accepted connections を
含む probe 全体の snapshot です。

| Connections | Process 数（前 / idle / active / 後） | Idle 時の heap 減少 | Active 時の heap 減少 |
| ---: | --- | ---: | ---: |
| 1 | `4 / 13 / 21 / 4` | 6,396–6,420 B | 11,508–13,060 B |
| 2 | `4 / 19 / 35 / 4` | 10,568–10,572 B | 22,280–23,784 B |
| 3 | `4 / 23 / 48 / 4` | 13,656–13,704 B | 32,608–34,176 B |
| 4 | `4 / 28 / 61 / 4` | 16,760–17,560 B | 40,116–44,040 B |

全 cycles で process 数は4へ戻り、free heap は probe の 32 KiB recovery bound 内へ回復しました。
2 connections 以上では `event_queue` warning を観測しています。4 connections は確認済みの上限であり、
一般的な安全上限ではありません。詳細は [TCP リソース上限の調査](atomvm-tcp-investigation.md) を参照してください。

## 実 RS485

2026-10-10 に XIAO ESP32-C5 × 2、HW-519 × 2、RTU 9,600 baud、8N1、Unit ID `1`、
poll interval 100 ms で約5分間実行しました。1,623 requests が成功し、失敗はありませんでした。

| Role | Steady free heap | Minimum free | Process 数 | Mailbox |
| --- | ---: | ---: | ---: | ---: |
| Client | 145,632–146,080 B | 143,652 B | 6–7 | 0 |
| Server | 136,684–137,424 B | 133,140 B | 7 | 0 |

この結果は短時間の baseline です。長時間運転や別構成の安定性を保証しません。

## 継続計測

長時間の推移は `MODBUS_HEALTH_INTERVAL_MS`、TCP の比較は `MODBUS_RESOURCE_PROBE=true` を使います。
手順と出力項目は [実機での追加検証](hardware-tests.md) を参照してください。

resource probe のログは次の script で CSV 化できます。

```sh
python3 scripts/summarize_tcp_resources.py \
  --label LABEL --atomvm-ref ATOMVM_REF --device DEVICE \
  --output /tmp/avmodbus-tcp-resource-history.csv --append \
  /tmp/avmodbus-tcp-probe.log
```

比較時は board、runtime、toolchain、compile-time 設定、connections、cycles を揃えてください。
