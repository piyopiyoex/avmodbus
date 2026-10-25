# Controller global queue budgetのhost・3台実機検証

## 目的

Controllerの複数`ModbusUART` streamが持つoutgoing queue合計を、peer数によらないbyte / chunk上限で制限する。
host実装とtestでrelease semanticsを固定した後、3台実機で通常mission、32+32 concurrent traffic、queueとheapを測定する。

## 実装

`DisterlProbe.QueueBudget`を、複数adapterが共有するlocal `GenServer`として追加した。adapterはwrite全体をqueueする前に
必要なpayload bytesとchunk数を予約する。予約と上限判定は1 process内で直列化されるため、複数peerの同時writeでも合計値を
原子的に更新する。

Controllerの既定値は次のとおりである。

| 対象 | Byte上限 | Chunk上限 |
| --- | ---: | ---: |
| 各stream | 8,192 | 256 |
| Controller全体 | 8,192 | 256 |

global上限は`ROBOT_MULTINODE_GLOBAL_MAX_QUEUED_BYTES`と
`ROBOT_MULTINODE_GLOBAL_MAX_QUEUED_CHUNKS`で変更できる。既存のstream別上限は独立した安全弁として残す。

## Host test

次を確認した。

- 2 ownerの予約合計がbyteまたはchunk上限を超えるwriteを`{:error, :global_queue_full}`で拒否する
- 32 ownerが同時に上限へ達しても256 bytes / 32 chunksを超えない
- 16 ownerの解放後、別ownerが解放分を再利用できる
- ACK相当の使用量同期で容量を解放する
- peer session変更でstale queue分を解放する
- adapterの正常終了と異常終了の両方で容量を解放する
- 拒否されたwriteはpartial queueを残さず、該当adapterのlocal sessionだけを更新する
- host scale modelでは1、2、3、8、32 peersのeffective上限が既定で8,192 bytes / 256 chunksに留まる

実行結果は次のとおりである。

```text
hello_atomvm_modbus_disterl: 78 tests, 0 failures
hello_atomvm_modbus_robot: 107 tests, 0 failures
```

## 3台実機検証

### 条件

- 3 × Seeed Studio XIAO ESP32-C5
- AtomVM `release-0.7` snapshot `18b35870` + local patch `a1069573`
- 115,200 baud、96-byte chunk、20 ms poll、breadboard hub配線
- Controller global budget: 8,192 bytes / 256 chunks
- Drive / Sensors各32 messages、64-byte application payload、application ACK window 1
- 3台をsoftware resetし、両remote接続、probe、sensor-driven missionの後にtrafficを開始

最初のrunは通常remote firmware、2回目はremote heapを観測するためDrive / Sensorsでも`MODBUS_TRACE_QUEUE=true`とした。

### 結果

| 指標 | Run 1 | Run 2 |
| --- | ---: | ---: |
| Traffic outcome | complete | complete |
| Drive / Sensors delivery | 32 / 32、32 / 32 | 32 / 32、32 / 32 |
| Duplicate / missing / invalid | 0 / 0 / 0 | 0 / 0 / 0 |
| Elapsed | 104,382 ms | 102,022 ms |
| Global high-water | 900 bytes / 14 chunks | 906 bytes / 14 chunks |
| Global rejection | 0 | 0 |
| Controller minimum free heap | 65,892 bytes | 65,852 bytes |
| Drive minimum free heap | 未採取 | 77,604 bytes |
| Sensors minimum free heap | 未採取 | 82,816 bytes |
| Transaction failure | Drive 1、Sensors 0 | Drive 0、Sensors 0 |

Run 1のDrive transaction timeout 1回後もapplication messageは完全配送した。Run 2では両Unitともtransaction failure 0だった。
traffic完了直後のglobal使用量はRun 2で270 bytes / 4 chunks、30秒後は0 bytes / 0 chunks、active owner 0へ戻った。
両runともglobal拒否、carrier queue-full、distribution restartは観測しなかった。

remoteのminimum値はqueue traceとconsole出力を有効にした測定であり、global budget追加前との差分やqueue単体の消費量ではない。
それでも同じ32+32 workload中に各remoteが正のheap余裕を維持したことと、Controllerの共有予約がdrain後に残らないことは確認できた。

## 境界

このbudgetはcarrierが保持するpayloadとchunk件数だけを数え、AtomVM heap全体を直接制限しない。binary header、process、mailbox、
distribution controller、AVModbus transactionのmemoryは別に測定する必要がある。またglobal拒否はbackpressure待機ではなく、
対象streamをfail fastさせる。

短時間の2 runはmemory leakや長時間安定性を示さない。この時点で後続課題だった長時間通信断と約1時間のidle / active反復は、
[長時間通信断・安定性test plan](../endurance-test-plan.md)に沿って実施済みである。
