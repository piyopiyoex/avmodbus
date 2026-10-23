# Readiness ACK間隔とtimeout余裕の基準値 — 2026-10-23

## 目的

mission worker分離後のreadiness ACK間隔を、通常missionとconcurrent trafficを含む負荷で直接測定する。
分離前に25秒timeoutで発生したfalse positiveに対し、現在実装のprofile固有の安全余裕を定量化する。

## 実装とhost検証

`RobotSim.RemoteHealth`へ次のboot内metricsを追加した。

- 現在connectionで受け取ったACK数
- board boot中に受け取ったACK総数
- connectionをまたいで保持するACK gap high-water

各distribution connectionの初回ACKはhandshake所要時間を含むためgap集計から除外する。stale connection IDのACKは従来どおり
healthもmetricsも更新しない。reconnect時はconnection内countだけを0へ戻し、boot内countとhigh-waterを保持する。

`ROBOT_MULTINODE_REMOTE_HEALTH_TRACE=true`のときだけrole、connection ID、今回のgap、boot内high-water、ACK総数を出力する。
通常firmwareでは既定の`false`であり、wire protocolとAVModbus coreは変更していない。

hostではinitial ACKの除外、連続ACKのhigh-water、reconnect後のhigh-water保持を確認した。robot exampleは76 tests、
root projectは228 tests + 6 propertiesで、すべてfailure 0だった。3 roleのAtomVM compatibility checkとPackBEAM buildにも成功した。

## 実機条件

- 3 × Seeed Studio XIAO ESP32-C5
- breadboard railのcontinuous A/B trunk、node別branch、共通GND
- AtomVM v0.7.0-beta.0と既存multi-connection local patch
- 115,200 baud、FC-100 chunk payload 96 bytes
- Drive / Sensors: announce 10秒、remote health有効、trace有効、ACK timeout 120秒、restart上限0
- Controller: 32 messages / role、64-byte payload、interval 500 ms、application ACK window 1
- Controller: traffic timeout 300秒、application ACK timeout 30秒、retry 2回、settling 30秒
- response faultなし

remote ACK timeoutは測定を中断しない120秒とした。観測したgapから短いtimeoutを評価するのであり、120秒を推奨値として
検証する試験ではない。

## Readiness ACKの間隔

通常の3-step sensor missionからconcurrent trafficとsettling完了後まで同じconnectionを監視した。

| Role | ACK count | 最大gap | health restart / timeout |
| --- | ---: | ---: | ---: |
| Drive | 24 | 11,532 ms | 0 |
| Sensors | 24 | 11,532 ms | 0 |

10秒announceに対し、観測した最大の追加遅延は1,532 msだった。25秒timeoutとの差は13,468 ms、既定の90秒timeoutとの差は
78,468 msである。いずれもこのrunで観測した差にすぎず、将来のgap上限ではない。

分離前の同期missionで観測した25,537 msは今回再現しなかった。missionをlocal workerへ分離したためController health loopが
remote reply待ちから独立した効果と整合する。ただし初回handshake、recovery probe、異なるtraffic負荷、長時間運転は同じ分布を
保証しない。

## 同時通信の結果

run `2467400923`は103,203 msでcompleteした。

| Metric | Drive | Sensors |
| --- | ---: | ---: |
| expected / received | 32 / 32 | 32 / 32 |
| missing / duplicate | 0 / 0 | 0 / 0 |
| out-of-order / invalid | 0 / 0 | 0 / 0 |
| duration | 95,859 ms | 98,880 ms |
| sample span | 91,310 ms | 94,477 ms |
| throughput | 333 milli-msg/s | 323 milli-msg/s |
| max interarrival | 3,682 ms | 4,166 ms |

start skewは763 ms、active overlapは95,096 ms、completion skewは3,784 ms、delivery ratio gapは0‰だった。

## キューとメモリーの測定

| Phase / role | success / failure | queue bytes / chunks | max queue bytes / chunks | free heap | minimum |
| --- | ---: | ---: | ---: | ---: | ---: |
| complete / Drive | 205 / 0 | 0 / 0 | 199 / 3 | 82,836 | 76,428 |
| complete / Sensors | 206 / 0 | 137 / 2 | 322 / 5 | 81,132 | 76,428 |
| settled / Drive | 272 / 0 | 0 / 0 | 199 / 3 | 82,404 | 76,428 |
| settled / Sensors | 272 / 0 | 0 / 0 | 322 / 5 | 81,732 | 76,428 |

complete時のSensors queueは30秒後に0へdrainし、両roleのoutstandingも0だった。transaction failureは0だった。

## 通常構成への復元確認

3 roleをtraffic、remote health、trace、fault無効の通常構成でcheck、pack、flashした。imageはDrive 264,348 bytes、
Sensors 264,320 bytes、Controller 267,924 bytesだった。

両distribution connectionとprobeが成功した後、fresh stateの3-step missionは`forward 100`、`forward 100`、`right 90°`を実行し、
final statusは`{x_mm: 200, y_mm: 0, heading_deg: 90}`だった。

## 結論

現在のmission worker構成では、10秒announceと32+32 flow-controlled trafficの単一runでreadiness ACK gap high-waterは
両roleとも11,532 msだった。25秒timeoutに対する観測上の余裕は13,468 msだが、これをtimeout保証や推奨最小値とはしない。

次は異なる負荷と長時間runで分布を反復測定する。障害検出timeoutは、正常時の測定値だけでなくbus fault時の検出時間とのtrade-offを
明示して選ぶ必要がある。
