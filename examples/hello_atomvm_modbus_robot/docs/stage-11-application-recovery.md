# Stage 11 application recovery統合試験

状態: 完了

## 目的

Sensorsの通信断でmissionが停止した後、distribution接続の復旧とapplicationの安全な復旧を区別して確認する。停止したmissionは
自動再開せず、新しいsensor sampleとDriveの現在stateを非変更probeで取得する。

## 判定境界

Mission結果は次の3種類に分ける。

| Outcome | Action | 意味 |
| --- | --- | --- |
| `completed` | `none` | 全stepと最終statusを確認した |
| `aborted` | `stop` | Sensor timeoutなど、movement commandを未確定にせず停止した |
| `indeterminate` | `snapshot` | Drive boot変更によりcommand結果を確定できず、guarded snapshotが必要 |

Sensors再接続後のprobeは、fresh sample取得、Driveへのrelay、boot ID付き`:status`だけを実行する。Movement command、mission resume、
durable state更新は行わない。Probeは`ROBOT_MULTINODE_APPLICATION_RECOVERY_PROBE_ENABLED=true`のときだけ有効にする。

## 実機scenario

1. Controllerだけ`ROBOT_SENSOR_MISSION_STEP_DELAY_MS=120000`とし、3台をclean bootする
2. 最初のsensor-driven mission stepを確認する
3. 120秒のstep間隔中にSensors branchを切断する
4. Missionが`aborted / stop`で終了し、Driveが継続することを確認する
5. Remote healthがrestartを保留した後にbranchを復帰する
6. Sensors / Drive両probeの成功後、application recovery probeを確認する
7. 新しいsample、Drive boot ID、rover state、queue、free heapを記録する

初回はSensorsのdeferred restartを使い、mission command timeoutやrestart上限を増やさない。Application probeが成功してもmissionを
再開しないことを確認する。

## 完了条件

- Mission timeoutを明示的な`aborted`として記録できる
- Sensors再接続後にfresh sampleとguarded Drive statusを取得できる
- Drive stateとrequest ID重複抑止を壊さない
- 正常なDrive connectionを維持する
- 復旧後のqueue、memory、application stateをworklogに残す

Indeterminate commandは既存のboot ID guardとsnapshotをhost testで維持し、Sensors切断scenarioと混同しない。

## 結果

2026-10-28の3台実機試験では、step 1の100 mm前進後にSensors branchを切断した。Step 2のsensor requestはtimeoutし、missionは
`aborted / stop`で終了した。Drive connectionを維持したままSensorsを再接続・再起動し、fresh sampleとguarded `:status`を取得した。
Drive stateは`x=100 mm, y=0 mm, heading=0°`のままで、step 2のmovementやmission自動再開は発生しなかった。

Queueは0 bytes / 0 chunksまで排出され、global rejectionは0だった。詳細なevent、memory、試験条件は
[実機作業記録](worklog/2026-10-28-stage-11-application-recovery.md)を参照する。この単一scenarioはdurable resumeや任意の障害からの
回復を保証しない。
