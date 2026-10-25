# 長時間通信断・安定性test plan

3台構成のまま、短時間baselineでは分からない接続復旧とmemory推移を検証します。対象はexperimental exampleであり、
Modbus RTU一般やproduction運用の保証には使いません。

## 共通条件

- 3 × Seeed Studio XIAO ESP32-C5
- AtomVM `release-0.7` snapshot `18b35870` + local patch `a1069573`
- 115,200 baud、96-byte chunk、20 ms poll
- breadboard上のcontinuous A/B trunkと、role別に外せるbranch
- Controller、Drive、Sensorsのserial logを別ファイルへ保存する
- 3 roleで`ROBOT_MULTINODE_CONNECTION_TRACE=true`を有効にする
- 30秒以上の計測間隔で`ROBOT_MULTINODE_METRICS_INTERVAL_MS`を有効にする

試験前後に3台のfirmware設定、USB serial IDとrole対応、開始・終了時刻をworklogへ記録します。branchを外す時刻と戻す時刻は
Controller logの時刻だけで推測せず、操作時にも記録します。

## Scenario A: 単発の長時間通信断

Sensors branchを30秒、90秒、180秒外し、各時間を独立したboard bootで試します。短い試験でrestart budgetを消費した状態を
次の試験へ持ち越さないためです。

各runで次を確認します。

1. 切断前にDrive / Sensors両方のconnectionとtrafficを確認する。
2. Sensors branchだけを外し、Driveのmessage deliveryとconnection eventを継続観測する。
3. 指定時間後にbranchを戻し、Sensorsの再接続または明示的な回復不能状態まで観測する。
4. Drive / Sensorsのreceived、missing、duplicates、out_of_orderとapplication retryを記録する。
5. `restart_started`、`restart_succeeded`、`restart_budget_exhausted`の回数を記録する。

成功は「必ず自動復旧すること」だけを意味しません。正常peerを維持した上で対象peerが再接続するか、board resetなしでは
復旧しない具体的な状態とrestart budgetを再現できれば、実験結果として成立します。

## Scenario B: 同一peerの反復切断

Sensors branchの30秒切断・復帰を同一bootで3回反復します。各復帰後に両roleの疎通を確認してから次を開始します。
restartを伴わない短い切断でもmessage欠損やconnection stateが累積するかを調べます。途中でrestart budgetを消費した場合は、
その時点以降を別のfailure modeとして記録し、成功扱いに合わせてboardをresetしません。

2026-10-25の実機試験では、同じSensors connectionのまま3回とも復帰し、3 traffic runsを完全配送しました。操作時間の
精密測定ではないため、連続timeout区間とreadiness ACK gapを分けた結果は
[反復切断worklog](worklog/2026-10-25-repeated-branch-disconnect.md)を参照してください。

## Scenario C: 約1時間のactive / idle反復

基準profileは次のとおりです。

| 設定 | 値 |
| --- | ---: |
| `ROBOT_MULTINODE_TRAFFIC_SAMPLES` | 16 |
| `ROBOT_MULTINODE_TRAFFIC_RUNS` | 12 |
| `ROBOT_MULTINODE_TRAFFIC_IDLE_MS` | 270000 |
| `ROBOT_MULTINODE_METRICS_INTERVAL_MS` | 60000 |
| `ROBOT_MULTINODE_TRAFFIC_PAYLOAD_BYTES` | 64 |

過去の16+16 / 32+32実測から約1時間になるよう選んだ値であり、wall-clock durationそのものを保証しません。開始時刻から
12 run完了または明示的な失敗までを測り、実時間も別に記録します。

次を合格条件とします。

- 12 runすべてが`outcome=complete`で、missing、duplicates、invalidが0
- global budget rejectionが0で、queueがidle中にdrainする
- 予期しないdistribution restartとtransaction failureの増加がない
- 3 roleのminimum free heapが正で、時間とともに一方向へ減り続ける明確な傾向がない
- serial log欠損や集計不能行をworklogで明示する

2026-10-25の実機試験では64分30秒の12 runsをすべて完全配送し、restartとglobal rejectionは0でした。Sensorsで
retry可能なtransaction timeoutを8件観測したため、無失敗条件は未達として扱います。memory推移を含む結果は
[約1時間の耐久試験worklog](worklog/2026-10-25-one-hour-active-idle-endurance.md)を参照してください。

## 集計

3 roleのlogを次のcommandで集計します。

```sh
mix run scripts/endurance_report.exs controller.log drive.log sensors.log
```

同じlogに事前確認、別boot、試験後の追加観測が含まれる場合は、3 roleで共通する開始・終了時刻を指定します。
時刻は同じ日の`HH:MM:SS.mmm`で、指定範囲外の行とtimestampのない行を集計から除外します。

```sh
mix run scripts/endurance_report.exs \
  --since 09:32:23.000 \
  --until 10:37:36.082 \
  controller.log drive.log sensors.log
```

`RobotSim.EnduranceReport`は次を集計します。

- traffic complete / timeout / other件数
- planned / started / outcome取得済みrun数と、campaign全体の完了状態
- Controller minimum free heap、global queue high-water、global rejection
- peer別queue high-waterとtransaction failure
- Drive / Sensorsのminimum free heap
- stale検出、connection restart、restart失敗、reconnect、復旧確認event数

periodic logは観測点であり、連続的な最大値・最小値ではありません。reportの`successful: true`は読み込んだlogの整合とtraffic完了を
表し、開始したrestartがすべて成功していることを確認します。memory leakがないことや任意の通信断から復旧することは証明しません。
