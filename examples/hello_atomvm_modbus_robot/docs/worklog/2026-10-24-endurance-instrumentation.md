# 長時間通信断・安定性試験の計測基盤

## 目的

30 / 90 / 180秒の通信断と約1時間のactive / idle反復を、boundedなruntime stateと3 roleの時系列logで測定できるようにする。
この記録はhost実装の検証までを対象とし、長時間の実機結果はまだ含まない。

## 実装

- `ROBOT_MULTINODE_TRAFFIC_RUNS`で既存traffic probeを逐次反復する
- `ROBOT_MULTINODE_TRAFFIC_IDLE_MS`でrun間にidleを置く
- `ROBOT_MULTINODE_METRICS_INTERVAL_MS`で3 roleのresource snapshotを定期出力する
- `RobotSim.Endurance`はactive runを1個に制限し、件数だけをboundedに集計する
- `RobotSim.EnduranceReport`は保存したController / Drive / Sensors logをhost上で集計する

wire format、AVModbus core、distribution carrier、既存のqueue / retry policyは変更していない。既定値ではtrafficの反復は1回、
periodic metricsは無効であり、通常のmultinode実行へ定期timerを追加しない。

## Host test

`mise exec -- mix format`と`mise exec -- mix test`を実行し、113 tests、failure 0を確認した。testは次を含む。

- runを1個ずつ開始し、complete / timeout / otherをboundedに集計する
- active runの重複開始とactive runなしの完了を拒否する
- 3 roleのresource、memory、traffic、connection eventを集計する
- runごとにresetされるtransaction failure counterを差分で合計する
- timeoutと壊れた機械可読logを成功扱いにしない
- remote metricsが欠けたlogを成功扱いにしない

## AtomVM compatibility check

Controllerは4+4 messages、2 runs、5秒idle、2秒metrics、Drive / Sensorsは2秒metricsを有効にして、3 roleの
`MIX_ENV=prod mix atomvm.check`を実行した。すべて成功し、新しい状態機械、timer、`MemorySnapshot`呼び出しが現在の
AtomVM向けsubsetでcompileできることを確認した。

## 3台実機スモーク

### 条件

- 3 × Seeed Studio XIAO ESP32-C5
- AtomVM `release-0.7` snapshot `18b35870` + local patch `a1069573`
- 115,200 baud、breadboard hub配線
- Controller: 4+4 messages、32-byte payload、2 runs、5秒idle、2秒settled metrics
- 3 role: 5秒periodic metrics、connection trace有効

3 roleのPackBEAM buildとflashに成功した。両remote接続、probe、sensor-driven mission完了後に2 runを実行した。

### 結果

| 指標 | 結果 |
| --- | ---: |
| Traffic run | 2 / 2 complete |
| Drive delivery | 各run 4 / 4 |
| Sensors delivery | 各run 4 / 4 |
| Missing / duplicates / invalid | 0 / 0 / 0 |
| Run 1 elapsed | 20,917 ms |
| Run 2 elapsed | 21,720 ms |
| Controller minimum free heap | 64,084 bytes |
| Global queue high-water | 394 bytes / 6 chunks |
| Global rejection | 0 |
| Drive minimum free heap | 77,668 bytes |
| Sensors minimum free heap | 81,288 bytes |
| Transaction failure | Drive 0、Sensors 0 |
| Distribution restart / reconnect | 0 / 0 |

各runのsettled metricsでglobal queueは0 bytes / 0 chunks、active owner 0へ戻った。run間idle後に2本目が開始され、
終了後も約4分間periodic metricsを継続した。Drive / Sensorsの観測free heapはactive traffic後に回復し、短時間の観測範囲では
一方向の減少を示さなかった。

保存した3 roleのserial logを`mix run scripts/endurance_report.exs`へ渡し、planned / started / completedが2、
traffic complete 2、malformed 0、`successful: true`を確認した。raw logはlocal `/tmp`へ保存した一時成果物であり、
repositoryには集計値と再現条件を残す。

この結果は反復機構と計測経路のスモークであり、30 / 90 / 180秒の通信断や1時間のmemory stabilityを検証したものではない。

## Regression

実機スモーク後に各projectのformatとhost testを再実行した。

| Project | 結果 |
| --- | ---: |
| AVModbus root | 6 properties、228 tests、failure 0 |
| `hello_atomvm_modbus_disterl` | 78 tests、failure 0 |
| `hello_atomvm_modbus_robot` | 113 tests、failure 0 |

`git diff --check`も成功した。

## この時点で未検証だった項目

- 30 / 90 / 180秒のbranch切断
- 同一bootでの反復切断
- 約1時間のactive / idle運転とmemory推移

実機条件と判定基準は[長時間通信断・安定性test plan](../endurance-test-plan.md)を正とする。
これらの後続結果は[作業記録index](README.md)の2026-10-24〜25の各記録を参照する。
