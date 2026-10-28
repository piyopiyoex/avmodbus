# Stage 11 application recovery観測基盤

## 目的

Distribution接続の復旧後にapplicationが安全な状態を確認できるか、mission自動再開を導入せず検証する。

## 実装

- Mission failureを`aborted / stop`と`indeterminate / snapshot`へ分類した
- Sensors再接続後にだけ有効化できるapplication recovery probeを追加した
- Probeはfresh sensor sampleをDriveへrelayし、現在のDrive boot IDでguardした`:status`を読む
- Movement commandとmission resumeは実行しない
- Controller health loopを塞がないよう、probeを別processで実行する
- 物理切断の操作窓を固定するため、通常は0 msのstep間隔を実機profileだけ10,000 msに設定できるようにした

既定値は無効であり、`ROBOT_MULTINODE_APPLICATION_RECOVERY_PROBE_ENABLED=true`でControllerだけに有効化する。

## Host検証

`mise exec -- mix test`は148 tests、0 failuresだった。次を確認した。

- Sensor timeoutを明示的なmission abortへ分類する
- Drive boot変更をindeterminate outcomeへ分類する
- Fresh sampleをrelayした後もrover positionが変化しない
- Sensor replyがない場合にbounded timeoutを返す
- Step間隔は完了したstep間だけに適用し、最後のstep後には待たない

Controller、Drive、Sensorsの`mix atomvm.check`も成功した。実機条件と判定項目は
[Stage 11試験計画](../stage-11-application-recovery.md)を正とする。

## 実機結果

未実施。
