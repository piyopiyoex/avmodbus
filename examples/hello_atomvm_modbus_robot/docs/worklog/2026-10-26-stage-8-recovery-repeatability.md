# Stage 8 recovery policy反復試験

## 目的

Sensors branchの長時間切断に対し、ACK timeout時に直ちにdistributionを再起動するcurrent policyと、FC-100 exchangeの復帰まで
再起動を保留するdeferred policyを同じ計測項目で比較する。

## 環境

- 3 × Seeed Studio XIAO ESP32-C5
- 3 × HW-519 TTL-to-RS485 transceiver
- Breadboard上のcontinuous A/B trunkとnode別branch
- AtomVM v0.7 snapshot `18b35870` + local compatibility patch `a1069573`
- 115,200 baud、poll interval 20 ms、chunk 96 bytes
- Remote ACK timeout 90秒、restart上限1回、transport ready判定2 exchanges
- Fault injection、concurrent trafficは無効

各run前に3台をresetし、Drive / Sensorsの接続とapplication probeを確認した。目標切断時間は120秒または300秒としたが、
operator操作の遅れがあるため、結果ではremote adapterが記録した`transport_gap_ms`を使用する。

## 結果

| Policy | 目標 | Run | FC-100 gap | 結果 | ready→probe | Sensors minimum watermark |
| --- | ---: | ---: | ---: | --- | ---: | ---: |
| Current | 120秒 | 1 | 未観測 | 失敗 | — | 77,964 bytes |
| Current | 120秒 | 2 | 112.950秒 | 失敗 | — | 67,088 bytes |
| Current | 300秒 | 1 | 289.082秒 | 失敗 | — | 56,508 bytes |
| Current | 300秒 | 2 | 248.129秒 | 失敗 | — | 58,280 bytes |
| Deferred | 120秒 | 1 | 166.510秒 | 成功 | 10.787秒 | 81,640 bytes |
| Deferred | 120秒 | 2 | 239.372秒 | 成功 | 12.119秒 | 81,264 bytes |
| Deferred | 300秒 | 1 | 393.908秒 | 成功 | 12.023秒 | 79,264 bytes |
| Deferred | 300秒 | 2 | 337.038秒 | 成功 | 10.690秒 | 79,888 bytes |

`minimum watermark`はAtomVMがboot中に観測したfree heapの最小値であり、表のtime window内に定期出力された値だけを使う
`minimum_observed_free_heap_bytes`とは異なる。

### Current policy

4回ともphysical transport復帰前にrestartを開始し、1回のrestart budgetを消費した。復線後に`transport_ready`を記録した3回も、
Controllerへの再接続とapplication probeには到達しなかった。Current 120秒 Run 1はobserver eventを記録できず、gapを推定していない。

- 成功: 0 / 4
- restart budget exhaustion: 4 / 4
- Drive connectionの維持: 4 / 4
- global queue rejection: 0
- Controller global queue high-water: 773–1,023 bytes、12–16 chunks

Current policyではremote adapterがrestart時に再生成される。そのため`transport_gap_ms`は新しいadapterが観測した区間だけを表し、
physical branchの切断時間全体より短い場合がある。

### Deferred policy

4回とも`restart_deferred`を記録し、復線後に2回の有効なFC-100 exchangeを確認してからrestartした。`transport_ready`から
`restart_started`までは33–34 ms、restart自体は210–212 msだった。Controller再接続はrestart成功から4.605–6.025秒、
SensorsとDriveのprobe完了はtransport readyから10.690–12.119秒だった。

- 成功: 4 / 4
- restart budget exhaustion: 0 / 4
- Drive connectionの維持: 4 / 4
- queue drain: 4 / 4
- global queue rejection: 0
- Controller global queue high-water: 658–1,019 bytes、10–16 chunks

Sensorsのminimum watermarkは79,264–81,640 bytesだった。Stage 7以前のcurrent policyで観測した、restart後にfree heapが継続して
低下する挙動は今回のdeferred 4 runsでは観測しなかった。

## 判定

Deferred policyは今回の物理branch切断に対して再現性のある改善を示した。ただし2 runs / conditionの探索的試験であり、任意の切断時間、
負荷、配線条件での復旧保証ではない。Serverがrequestを受信し続ける非対称response blackoutではFC-100 gapが成立しないため、
`ROBOT_MULTINODE_DEFER_RESTART_UNTIL_TRANSPORT_READY`は既定値へ変更せずopt-inを維持する。

次はStage 9でrequest受信とresponse deliveryを区別し、現在のtransport activity signalが扱えない非対称障害を再現する。

## 証跡

各runは次の一時logへ保存した。repositoryには追加せず、この記録へ集計値だけを残す。

```text
/tmp/modbus-stage8-current-120s-r{1,2}-{controller,drive,sensors}.log
/tmp/modbus-stage8-current-300s-r{1,2}-{controller,drive,sensors}.log
/tmp/modbus-stage8-deferred-120s-r{1,2}-{controller,drive,sensors}.log
/tmp/modbus-stage8-deferred-300s-r{1,2}-{controller,drive,sensors}.log
```

集計にはrun固有の`--since` / `--until`と`--mode recovery`を指定した。操作手順と成功条件は
[Stage 8 recovery policy反復試験](../stage-8-recovery-repeatability.md)を参照する。
