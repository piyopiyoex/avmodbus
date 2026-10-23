# 256+256 trafficでのreadiness ACK gap長時間測定 — 2026-10-23

## 目的

10秒announceと32+32 trafficで得た11,532 msのreadiness ACK gap baselineを、より長い
256+256 flow-controlled trafficで再測定する。delivery、queue、Controller heapも同時に記録し、
25秒timeoutを正常時の安全値とみなせるか確認する。

## 条件

- 3 × Seeed Studio XIAO ESP32-C5
- breadboard railのcontinuous A/B trunk、node別branch、共通GND
- AtomVM v0.7.0-beta.0とmulti-connection tick local patch
- 115,200 baud、FC-100 chunk payload 96 bytes
- Drive / Sensors: announce 10秒、remote healthとtrace有効、ACK timeout 120秒、restart上限0
- Controller: 256 messages / role、64-byte payload、interval 500 ms、application ACK window 1
- Controller: traffic timeout 900秒、application ACK timeout 30秒、retry 2回、settling 30秒
- fault injectionと物理操作なし

run IDは`1075518060`である。初回handshakeを含む各connectionの最初のACKはgap集計から除外した。

## Traffic結果

runは783,317 msでcompleteした。

| Metric | Drive | Sensors |
| --- | ---: | ---: |
| expected / received | 256 / 256 | 256 / 256 |
| missing / duplicate | 0 / 0 | 0 / 0 |
| out-of-order / invalid | 0 / 0 | 0 / 0 |
| duration | 779,945 ms | 776,418 ms |
| sample span | 775,251 ms | 769,847 ms |
| throughput | 328 milli-msg/s | 329 milli-msg/s |
| max interarrival | 5,873 ms | 5,391 ms |

start skewは266 ms、active overlapは776,418 ms、completion skewは3,261 ms、delivery ratio gapは0‰だった。

## Transaction、queue、memory

| Phase / role | success / failure | average / max transaction | queue bytes / chunks | max queue bytes / chunks | free heap | minimum |
| --- | ---: | ---: | ---: | ---: | ---: | ---: |
| complete / Drive | 1,549 / 2 | 210 / 2,004 ms | 131 / 2 | 200 / 3 | 82,924 | 68,848 |
| complete / Sensors | 1,550 / 1 | 209 / 2,003 ms | 0 / 0 | 200 / 3 | 81,316 | 68,848 |
| settled / Drive | 1,616 / 2 | 209 / 2,004 ms | 0 / 0 | 200 / 3 | 82,800 | 68,848 |
| settled / Sensors | 1,617 / 1 | 208 / 2,003 ms | 0 / 0 | 200 / 3 | 82,256 | 68,848 |

開始前のController free heapはrole別snapshotで87,760 / 87,228 bytes、minimumは84,064 bytesだった。
traffic中のminimum watermarkは68,848 bytesまで下がったが、30秒settling後は両queueとoutstandingが0になった。
この値はController側VMとadapterの観測であり、Drive / Sensors側VM全体のmemoryを表さない。

## Readiness ACK gap

| Role | 観測終了時ACK count | 最大gap | health restart / timeout |
| --- | ---: | ---: | ---: |
| Drive | 362 | 23,586 ms | 0 |
| Sensors | 368 | 23,995 ms | 0 |

traffic完了後も同じconnectionと10秒heartbeatの監視を継続し、high-waterが増えないことを確認した。
最大gapは短い32+32 runの11,532 msより約12秒大きく、25秒timeoutとの差はDrive 1,414 ms、Sensors 1,005 msしかない。
faultがない単一runでもこの差まで縮んだため、25秒を一般的な安全値または推奨最小値にはできない。

ACK countはboard boot内の累積であり、traffic message数ではない。DriveとSensorsの差は初期接続とpolling順の差を含む。

## AtomVM v0.7 snapshotの確認

2026-10-23時点のAtomVM `upstream/release-0.7` HEAD `18b35870`でも、複数connectionのtick callbackは
send expressionの戻り値をそのまま`maps:fold/3`の次のaccumulatorへ渡していた。このため2個目のalive connectionで
`function_clause`になる既知問題は残っている。

最新snapshot上でsend後に`ok`を返す最小local patchと、2個のalive connectionを使う独立regression testを作成した。
generic Unix buildで`test_estdlib` target、対象testの`Return value: ok`、erlfmt v1.7.0を確認した。これはAVModbusの
local compatibility patchとして管理し、AtomVM upstreamへのIssueまたはPRは作成しない。実機runは従来の検証済みlocal patchを
含むruntimeであり、`18b35870` imageを実機検証した結果ではない。

local検証commitは`a1069573`、従来の実機patchは`74840ccc6f27ee060209de7c05ffc96204249d48`である。最小修正と最初の実機再現は
[Stage 3 worklog](2026-10-19-stage-3-three-node-distribution.md)も参照する。

## 通常構成への復元

3 roleをtraffic、remote health、trace、fault無効の通常構成でcheck、pack、flashした。imageはDrive 264,348 bytes、
Sensors 264,320 bytes、Controller 267,924 bytesだった。

両distribution connectionとprobeが成功した後、fresh stateの3-step missionは`forward 100`、`forward 100`、`right 90°`を実行し、
final statusは`{x_mm: 200, y_mm: 0, heading_deg: 90}`だった。

## 結論

256+256 trafficはapplication error 0で完全配送し、settling後のqueueも0になった。一方、正常時のreadiness ACK gapは
23,995 msまで伸びた。timeout marginは短いrunだけで決めず、負荷、継続時間、bus fault時の検出時間を分けて評価する必要がある。
数時間から日単位のmemory stabilityと、remote側VMのmemory推移は未検証である。
