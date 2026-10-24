# 0022: 初回接続のstale distributionをbounded restartする

## 状態

採用

## 背景

DriveまたはSensorsをControllerより先に起動すると、`net_kernel.start/2`は成功した後にAtomVMの
distribution setupが固定7秒でtimeoutする。remote processはreadiness ACK待ちを続けるが、後からControllerを
起動しても同一board boot内で60秒以内に自動復旧しなかった。対象remoteだけをresetすると復旧したため、
`serial_dist`の片側stateをteardownする必要がある。

## 判断

- 初回readiness ACK待ちが8秒を超えたremoteは、自分の`net_kernel`をstop / startする。
- AtomVMの7秒setup timerは変更しない。
- 初回復旧と接続後のremote healthは、`ROBOT_MULTINODE_REMOTE_MAX_RESTARTS`のboot単位budgetを共用する。
- 既定では初回復旧を有効、restart上限を1回とする。必要な場合は
  `ROBOT_MULTINODE_INITIAL_RECOVERY_ENABLED=false`で無効にできる。
- budgetは正常接続後も同じboot内で補充しない。

## 影響

- Drive / Sensorsとも、初回setup timeout後にboard resetなしで同一boot IDのまま復旧した。
- remote側全体の`net_kernel`をrestartするため、remoteが複数distribution connectionを所有する構成には適用できない。
- 初回復旧で上限を消費すると、同じboot中の後発障害ではremote health restartできない。
- 上限を増やすと、接続直前の遅いhandshakeを8秒期限で再び切断する可能性がある。実機baselineは1回のみとする。
- application workloadの再開、durable delivery、Controller側のpeer単位teardownは保証しない。
