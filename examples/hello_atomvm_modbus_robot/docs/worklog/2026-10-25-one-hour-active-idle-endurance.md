# 約1時間のactive / idle耐久試験

## 目的

3台のgenuine distributed Erlang connectionを維持したまま、boundedな同時trafficとidleを約1時間反復し、
message delivery、queue、transaction failure、connection event、3 roleのmemory推移を測定する。

## 条件

- 3 × Seeed Studio XIAO ESP32-C5
- AtomVM `release-0.7` snapshot `18b35870` + local patch `a1069573`
- 115,200 baud、96-byte chunk、20 ms poll、breadboard hub配線
- 12 runs、Drive / Sensors各16 messages / run、64-byte payload
- Drive 2,000 ms / Sensors 1,000 ms間隔、application ACK window 1
- run間idle 270,000 ms、traffic timeout 120,000 ms、settling 30,000 ms
- application ACK timeout 90,000 ms、retry 1
- remote readiness ACK timeout 90,000 ms、restart budget 1
- 3 roleのperiodic metricsは60,000 ms間隔

USB serial loggerの接続を確認してから3台をresetした。共通する正式な観測区間は
`09:32:23.000`からcampaign完了の`10:37:36.082`までである。endurance run 1の開始は`09:33:05.477`で、
12 runsの所要時間は64分30.605秒だった。

同じlog fileにはreset前の短い試行とcampaign完了後のidleが含まれるため、次のcommandで対象区間だけを集計した。

```sh
mix run scripts/endurance_report.exs \
  --since 09:32:23.000 \
  --until 10:37:36.082 \
  controller.log drive.log sensors.log
```

## 結果

### Application traffic

12 runsすべてが`outcome=complete`だった。各roleは合計192 / 192 messagesを受信し、全runでmissing、duplicates、
invalid、out-of-orderは0だった。

| 指標 | 結果 |
| --- | ---: |
| 完了run | 12 / 12 |
| Drive / Sensors受信 | 192 / 192 messagesずつ |
| Traffic timeout / other | 0 / 0 |
| Run elapsed最小 / 平均 / 最大 | 72,614 / 74,518 / 78,711 ms |
| Drive平均throughput | 225.8 milli-messages/s |
| Sensors平均throughput | 281.1 milli-messages/s |

### Transactionとconnection

endurance profile開始後、Driveのtransaction failureは0、Sensorsは8だった。Sensorsの内訳はrun 2で3件、
run 7後のidleで1件、run 8で1件、run 10で3件である。すべて単発の`:timeout`をretryで回復し、application
messageの欠損やdistribution restartには至らなかった。

3台reset直後からrun 1開始までにはDrive / Sensorsで各2件のstartup poll timeoutもあった。run開始時にadapter
metricsをresetするため上記8件には含めず、startup収束とprofile中のfailureを分けて扱う。

| 指標 | 結果 |
| --- | ---: |
| Drive / Sensors transaction failure | 0 / 8 |
| Stale検出 | 0 |
| Restart開始 / 失敗 / budget枯渇 | 0 / 0 / 0 |
| Reconnect / recovery event | 0 / 0 |
| Global queue rejection | 0 |

12 runsの完全配送、connection維持、retry後の継続は確認できた。一方、test planの「transaction failureが増加しない」
という厳しい条件は満たしていない。`EnduranceReport`の`successful: true`はcampaign完了、log整合、application traffic、
restart整合の判定であり、physical transactionが無失敗だったことを意味しない。

### Resource

| 指標 | 結果 |
| --- | ---: |
| Controller periodic samples | 198 |
| Controller minimum free heap | 64,028 bytes |
| Global queue high-water | 894 bytes / 14 chunks |
| Drive queue high-water | 314 bytes / 5 chunks |
| Sensors queue high-water | 318 bytes / 5 chunks |
| Drive remote samples / minimum watermark | 65 / 77,092 bytes |
| Sensors remote samples / minimum watermark | 65 / 80,888 bytes |
| Drive minimum observed periodic free heap | 83,352 bytes |
| Sensors minimum observed periodic free heap | 86,584 bytes |

最初のperiodic sampleはDrive 83,792 bytes、Sensors 88,544 bytes、最後はDrive 84,040 bytes、Sensors
88,860 bytesだった。active区間では一時的に低下し、idle中に約85 KiB / 89 KiBへ戻る推移を反復した。
minimum watermarkは段階的に小さくなったが、periodic free heapが時間とともに一方向へ減り続ける傾向は観測しなかった。

loggerはcampaign後も約52分のidleを記録した。11:29のperiodic値はDrive 85,052 bytes、Sensors 88,840 bytesで、
minimum watermarkもcampaign終了時の77,092 / 80,888 bytesから低下しなかった。この追加区間は12-run集計には含めていない。

## 判断

- 約1時間のactive / idle profileで12 runs、384 application messagesを完全配送した。
- Global queueは設定上限内で、rejection、stale検出、distribution restart、reconnectは0だった。
- 3 roleのfree heapは正を維持し、約65分のcampaignと追加52分のidleで単調減少を観測しなかった。
- Sensorsのretry可能なtransaction timeout 8件を観測したため、この構成をerror-freeとは扱わない。
- これは1回のprofileであり、数時間・数日、別baud rate、別配線、任意のworkloadの安定性を保証しない。

これにより、3台での約1時間active / idle試験とmemory時系列の記録を完了する。次の改善対象は、同じ試験の単純反復ではなく、
観測した散発timeoutの条件を再現できるか、またはより長い運転を行う具体的な仮説が生じた場合に限定する。
