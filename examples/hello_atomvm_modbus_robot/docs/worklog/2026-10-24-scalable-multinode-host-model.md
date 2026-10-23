# スケーラブルなマルチノードホストモデル

## 目的

3台（Controller 1台、2 remote peers）をphysical integration baselineとして維持し、deviceを1台ずつ追加せずに次を検証する。

- 任意件数のpeer descriptorの生成とvalidation
- N remote peersのround-robin順序とstarvation
- slow / failed peerが正常peerへ与える影響
- overload時のbounded queueとrejection
- session replacement時のstale queue破棄
- 3台実測を基準にしたqueue resource budget

このmodelはhost上のdeterministic simulationであり、RS485 signal integrity、UART timing、AtomVM scheduler、実heap allocationは
再現しない。

## 実装

`RobotSim.MultinodeModel`を`host/multinode_model.ex`にhost-only modelとして追加した。testとscriptが明示的にloadし、
firmware用の`lib/`とPackBEAM artifactには含めない。各roundは次の順で進む。

1. 指定されたpeerのsessionを置き換え、旧sessionのqueueを破棄する。
2. peerごとのarrivalをbounded queueへ追加し、上限超過分をrejectする。
3. descriptor順に1件ずつtransactionを実行する。
4. success時だけ指定件数をdrainし、failure時はqueueを保持する。

traceはround、peer、session、開始・終了時刻、outcome、delivery、残queueを保持する。randomnessとwall clockは使わない。
model内のqueue単位は抽象的なlogical itemであり、FC-100 payload byteやfragment chunkではない。byte / chunk上限は
resource budgetの算術で別に扱う。
symbolic descriptorはruntime atomを生成せず、Unit IDの上限247を共有する。実際のDrive / Sensors descriptorも同じvalidatorを通す。
加えて、実際の`DisterlProbe.PollScheduler`に1、2、3、8、32 adaptersを登録し、4 roundsのtoken順を直接検証するtestを
追加した。

## 実行方法

```sh
cd examples/hello_atomvm_modbus_robot
mise exec -- mix test test/multinode_model_test.exs
mise exec -- mix run scripts/multinode_model.exs
cd ../hello_atomvm_modbus_disterl
mise exec -- mix test test/poll_scheduler_test.exs
```

実行日: 2026-10-24

host modelはfocused test 11 tests、PollSchedulerはfocused test 4 tests、いずれも0 failuresだった。

## 公平性

各peerのservice timeを1 ms、arrivalを0、4 roundsとして実行した。

| Remote peers | Polls / peer | Elapsed | Max active transaction |
| ---: | ---: | ---: | ---: |
| 1 | 4 | 4 ms | 1 |
| 2 | 4 | 8 ms | 1 |
| 3 | 4 | 12 ms | 1 |
| 8 | 4 | 32 ms | 1 |
| 32 | 4 | 128 ms | 1 |

全profileでdescriptor順が各roundに1回ずつ反復し、transactionの時間区間は重ならなかった。
`DisterlProbe.PollScheduler`自体のtoken配布も同じ1、2、3、8、32 adaptersで4 roundsの登録順を保持した。

3 peersのうち1 peerだけを50 ms、他を1 msとした3-round profileは156 msで完了し、全peerが3 pollsを受けた。poll countの
fairnessは維持するが、slow peerのservice timeは各cycleへ加算される。

## 障害、過負荷、復旧

8 peersの4番目を全4 roundsでfailure、service time 2,000 ms、queue limit 3とした。failed peerは4 failures、queue 3、
rejected 1となった。他の7 peersはそれぞれ4 successesを維持したが、全体時間は8,028 msだった。正常peerはstarveしなくても、
failed peerのtimeoutをroundごとに待つためlatencyは増える。

3 peers、arrival 2 / round、drain 1 / success、queue limit 3のoverload profileでは、各peerのmax queueは3、最終queueは2、
rejectedは2だった。queueは上限を超えないが、rejection後のapplication deliveryはmodel外のretry policyに依存する。

2 peersの一方をround 1–2でfailureとし、round 3でsession replacementした。旧queue 2件を`stale_discarded`として破棄し、
session 2で2件をdeliveryした。carrier sessionの回復は旧application messageのdeliveryを保証しないという実機baselineと一致する。

## リソース上限

defaultのstream別上限8,192 payload bytes / 256 chunksをremote peer数へ単純に掛けたconfigured limitと、実機で観測した
worst per-peer queue high-water 279 bytesを同じpeer数へ掛けたprojectionを分けて計算した。

| Remote peers | Configured payload limit | Configured chunk limit | Observed-scale queue projection |
| ---: | ---: | ---: | ---: |
| 1 | 8,192 bytes | 256 | 279 bytes |
| 2 | 16,384 bytes | 512 | 558 bytes |
| 3 | 24,576 bytes | 768 | 837 bytes |
| 8 | 65,536 bytes | 2,048 | 2,232 bytes |
| 32 | 262,144 bytes | 8,192 | 8,928 bytes |

比較基準は2026-10-23の256+256 runで観測したController minimum free heap 68,848 bytesである。configured payload limitは
事前確保量ではなく、VM heapにはbinary、process、mailbox、distribution controllerも含まれる。そのため8 peersの65,536 bytesが
watermark未満であることは安全性を意味しない。32 peersの262,144 bytesはwatermarkを超え、現在のper-stream defaultを独立に維持した
worst caseはESP32-C5の実memory budgetとして成立すると主張できない。

observed-scale projectionもtraffic profileが同じという仮定にすぎず、AtomVM heap projectionは`unknown`とした。実機connectionごとの
incremental heapを分離測定していないため、線形なfree-heap推定は行わない。

## 結論

- descriptor validationとround-robin policyは1、2、3、8、32 remote peersでdeterministically反復できる。
- 単一Clientとmax active transaction 1の制約はpeer数によらず維持できる。
- failed peerはpoll count上のstarvationを起こさないが、timeoutによるhead-of-line latencyは残る。
- bounded queueはgrowthを止めるが、drop / retry / durable deliveryを解決しない。
- session replacementではstale queueを破棄するため、application-level retryが必要である。
- current default queue limitをN streamsへ単純に複製する設計はresource budgetにならない。実機scale-out前にglobal budgetまたは
  peer数依存の上限設計が必要である。
- 4台以上のphysical distribution、3本以上のhandshake、実AtomVM heapは未検証のままである。

以上でStage 5のhost modelは完了とする。追加hardwareは、global resource policyや3本目のhandshakeなど、host modelでは答えられない
具体的な仮説が生じた場合だけspot checkに使う。

## 回帰確認

- repository root: 228 tests、6 properties、0 failures
- `hello_atomvm_modbus_disterl`: 68 tests、0 failures
- `hello_atomvm_modbus_robot`: 88 tests、0 failures
- 3 projects: `mix format --check-formatted` success
- Controller / Drive / Sensors: `mix atomvm.check` and `mix atomvm.packbeam` success
- 各roleのfirmware buildは19 modulesをcompileし、PackBEAM artifactに`RobotSim.MultinodeModel`を含まない
