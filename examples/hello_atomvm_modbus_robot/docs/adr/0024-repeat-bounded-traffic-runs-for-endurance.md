# 0024: Boundedなtraffic runを反復して長時間安定性を測る

## 状態

採用

## 背景

既存のconcurrent traffic probeは1 runの公平性、欠損、重複、queue high-waterを測定できる。一方、1時間の連続試験を
1個の巨大なrunとして実行すると、collector stateとapplication sequence数が試験時間に比例し、activeとidleのmemory推移も
区別しにくい。

## 判断

- 既存のboundedなtraffic runを順番に反復し、同時にactiveにするrunは1個だけとする。
- run間に設定可能なidle時間を置き、queue drainとfree heapを定期観測する。
- endurance stateはrun件数と結果件数だけを保持し、各sampleや過去summaryを蓄積しない。
- Controllerはpeer別resourceとglobal queue budget、remoteはfree heapを機械可読な1行logで出力する。
- 3 roleのserial logはhost専用`RobotSim.EnduranceReport`で集計し、生logを実測の正とする。
- 計測機能はopt-inとし、既定では反復1回、定期metrics無効とする。

## 影響

- active / idleを含む長時間試験を、runごとのbounded stateで実行できる。
- serial出力自体がtimingとmemoryへ影響するため、intervalを短くしすぎず、設定値をworklogへ残す必要がある。
- periodic sample間の瞬間的なheap最小値は取得できない。Controller adapterの既存minimum値とremoteの`MemorySnapshot` minimum値を
  併記する。
- 当初のreport成功判定はtraffic結果とlog整合だけを対象とした。Recovery-only判定への拡張は
  [ADR 0025](0025-separate-traffic-and-recovery-report-results.md)で分離して扱う。
- AVModbus core、FC-100 wire protocol、専用distribution carrierは変更しない。
