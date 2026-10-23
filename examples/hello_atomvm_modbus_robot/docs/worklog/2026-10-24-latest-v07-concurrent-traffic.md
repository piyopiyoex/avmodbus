# 最新 AtomVM v0.7 snapshotでの32+32 concurrent traffic — 2026-10-24

## 目的

2026-10-23に3台へ導入したAtomVM `release-0.7` snapshotとlocal tick patchを、通常missionだけでなく
flow-controlled concurrent trafficでも確認する。Drive / Sensorsの独立producer、2本のdistribution connection、shared Modbus Client、
readiness heartbeatを同時に動かし、delivery、fairness、queue、heap、ACK gapを記録する。

## Runtimeとhardware

- AtomVM baseline: `release-0.7` `18b35870`
- local multi-connection tick patch: `a1069573`
- 起動時revision: `0.7.0-beta.1+git.a1069573`
- ESP-IDF v5.5.5、ESP32-C5 release configuration
- 3 × Seeed Studio XIAO ESP32-C5、3 × HW-519
- breadboard railのcontinuous A/B trunk、node別branch、共通GND
- 115,200 baud、FC-100 chunk payload 96 bytes

native runtimeとboot libraryのbuild条件、hash、partition offsetは
[前日のruntime worklog](2026-10-23-latest-v07-runtime.md)を参照する。この試験では`main.avm` partitionだけをrole別に更新した。

| Role | Traffic firmware size | SHA-256 |
| --- | ---: | --- |
| Drive | 265,068 bytes | `d65682a277b23939af54f8e94cbefc42a42c302d25ceca0ba9fa889ecef7139a` |
| Sensors | 265,036 bytes | `5a0bd15a44ccd6bde8b8ad5f8b7187f92746b1feb7a5c6b35a63834595d930d5` |
| Controller | 268,656 bytes | `3c0d018216f4b1d461021e7c138037ef9390ddc15d9860e9f613e7293c5c01e4` |

3 roleともAtomVM compatibility checkとPackBEAM buildに成功した。

## Profile

- 32 messages / role
- 64-byte deterministic payload
- Drive / Sensors interval 500 ms
- application ACK window 1
- ACK timeout 30秒、retry 2回
- run timeout 300秒、settling 30秒
- readiness announce 10秒
- remote health ACK timeout 120秒、restart上限0
- remote health trace有効
- response faultと物理操作なし

## Traffic結果

run ID `669184555`は101,248 msでcompleteした。

| Metric | Drive | Sensors |
| --- | ---: | ---: |
| expected / received | 32 / 32 | 32 / 32 |
| missing / duplicate | 0 / 0 | 0 / 0 |
| out-of-order / invalid | 0 / 0 | 0 / 0 |
| duration | 97,135 ms | 97,651 ms |
| sample span | 92,600 ms | 93,140 ms |
| throughput | 329 milli-msg/s | 327 milli-msg/s |
| max interarrival | 3,703 ms | 4,055 ms |

start skewは245 ms、active overlapは96,890 ms、completion skewは761 ms、delivery ratio gapは0‰だった。

## Transaction、queue、memory

| Phase / role | success / failure | average / max transaction | queue bytes / chunks | max queue bytes / chunks | free heap | minimum |
| --- | ---: | ---: | ---: | ---: | ---: | ---: |
| complete / Drive | 202 / 0 | 207 / 260 ms | 35 / 1 | 197 / 3 | 82,760 | 76,712 |
| complete / Sensors | 203 / 0 | 207 / 260 ms | 135 / 2 | 197 / 3 | 80,992 | 76,712 |
| settled / Drive | 269 / 0 | 202 / 260 ms | 0 / 0 | 197 / 3 | 82,376 | 76,712 |
| settled / Sensors | 269 / 0 | 202 / 260 ms | 0 / 0 | 197 / 3 | 81,836 | 76,712 |

traffic開始前のfree heapはDrive snapshotで87,596 bytes、Sensors snapshotで87,064 bytes、minimumは83,700 bytesだった。
traffic中のminimum watermarkは76,712 bytesまで下がった。30秒settling後は両adapterのqueueとoutstandingが0になり、
transaction failureは両Unitとも0だった。

## Readiness ACK gap

traffic完了後に各remote consoleをresetせず観測した。

| Role | 観測時ACK count | 最大gap | health restart / timeout |
| --- | ---: | ---: | ---: |
| Drive | 23 | 15,681 ms | 0 |
| Sensors | 26 | 15,298 ms | 0 |

10秒announceに対する最大の追加遅延はDrive 5,681 ms、Sensors 5,298 msだった。前回32+32 runの11,532 msより大きいが、
別runの256+256で観測した23,995 msより小さい。単一runの値をtimeout保証には使わない。

## 通常firmwareへの復元

traffic、remote health、trace、faultを無効にした通常firmwareを3 roleへ再buildし、`main.avm`だけを書き戻した。

| Role | Normal firmware size |
| --- | ---: |
| Drive | 264,348 bytes |
| Sensors | 264,320 bytes |
| Controller | 267,924 bytes |

段階的にboardをresetすると、remote health無効の通常構成では先に確立した旧connectionがstaleになり、片方のremoteだけが
再接続する場合があった。また、Drive / Sensorsをconsoleで8秒ずつ確認してからControllerを起動した試行は、AtomVMの固定7秒
setup timerを超えて両handshakeがtimeoutした。

最終確認ではControllerをROM download modeで停止し、DriveとSensorsを1秒以内の間隔でhard resetしてから、直後にControllerを起動した。
両connectionとprobeが成功し、fresh rover stateから`forward 100`、`forward 100`、`right 90°`を実行した。最終stateは
`{x_mm: 200, y_mm: 0, heading_deg: 90}`だった。初期probe中にSensors Unitのtransaction timeoutを1回観測したが、retry後に
connectionとmissionは完了した。

この起動順は一般的な3-node recovery protocolではない。7秒setup timer、stale connection、remote health無効profileの境界を避けて、
通常構成へ確実に戻すための実験手順である。

## 結論

最新v0.7 snapshotとlocal tick patchの3台構成で、32+32 concurrent trafficをapplication error 0で完全配送した。
transaction failureは0、settling後のqueue / outstandingは0で、remote health timeoutとdistribution restartも観測しなかった。

これによりbasic missionに加えて短時間の同時負荷でもlocal compatibility baselineが動作することを確認した。一方、startupの固定7秒期限、
stale connection、長時間ACK gap、remote healthを無効にした通常profileの自動回復限界は残る。
