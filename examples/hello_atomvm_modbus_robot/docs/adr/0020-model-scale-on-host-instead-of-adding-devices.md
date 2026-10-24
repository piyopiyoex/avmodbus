# 0020: 実機を1台ずつ増やさずホストモデルで規模を検証する

## 状態

採用

## 背景

3台のXIAO ESP32-C5で、2本のdistribution connection、shared Modbus Client、concurrent traffic、単一branch障害、独立rebootを
検証した。次の案として4台目を追加する準備を始め、Controller transport setupをpeer descriptor list駆動へ変更した。

しかし4台、5台とphysical deviceを1台ずつ増やす方法は、peer数ごとの回帰を自動化できず、配線、USB port、operator timingに
結果が依存する。得られる1構成の結果に対して、継続的なtest costが大きい。

## 判断

3台構成（Controller 1台、2 remote peers）をphysical integration baselineとする。3 remote peers以上のscaleは、
任意件数のpeer descriptor、round-robin scheduling、failure / overload、queueとresource budgetをhost上の
deterministic modelで検証する。

追加hardwareは通常のroadmap milestoneにしない。host modelだけでは答えられない具体的なelectrical、UART、AtomVM runtimeの仮説が
生じた場合に限り、対象を絞ったspot checkとして追加deviceを使う。

[ADR 0019](0019-drive-controller-transport-from-peer-descriptors.md)のpeer-driven transport setupは維持する。ADR 0019に記載した
4台目を次の必須段階とする部分だけを、この判断で置き換える。

## 影響

- remote peer数1、2、3、8、32などをhost testで反復できる。
- fairness、starvation、failure isolation、queue growthを同じseedと条件で比較できる。
- AVModbus core、FC-100 wire protocol、既存3台firmwareを変更せずにscale設計を進められる。
- 4台以上のphysical distributionが動作するとは主張しない。
- host modelはRS485のsignal integrity、transceiver loading、実UART timing、AtomVMの実heap消費を再現しない。これらは3台実測との対応と、
  必要時のtargeted hardware testで区別して記録する。
