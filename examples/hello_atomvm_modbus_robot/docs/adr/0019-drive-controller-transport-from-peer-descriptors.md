# 0019: 4台化の前にController transport setupをpeer list駆動にする

## 状態

採用

## 背景

3台構成は2本のdistribution connection、32+32および256+256 concurrent traffic、単一branch障害からの復旧を実機確認した。
この結果から4台目を検討できる段階へ進んだが、Controllerのadapter生成、PollScheduler登録、`serial_dist` port生成、cleanupは
DriveとSensorsを個別変数で扱っていた。3本目を追加すると同じlifecycle codeをさらに複製することになる。

一方、robot application protocol、readiness state、mission、traffic metricsはDriveとSensorsの責務に強く依存する。transport setupを
一般化することと、未知の第4 roleをapplicationへ追加することは分けて検証する必要がある。

## 判断

Controllerのpeerをrole、Modbus Unit ID、Erlang node identityをまとめたdescriptor listで表す。次の処理はdescriptor順に行う。

- FC-100 adapterの生成
- PollSchedulerへの登録
- peer ready待ち
- `serial_dist`へ渡すUART port optionの生成
- roleからadapter / readiness stateへのmap生成
- partial failureと`net_kernel` start failure時のadapter cleanup

現在のdefault listはDrive Unit 1とSensors Unit 2の2件だけとする。application protocol、remote role、registered process、mission、
health policyは変更しない。AVModbus coreとFC-100 wire protocolも変更しない。

4台目の候補は`power@modbus.local` / Unit 3とするが、このADRでは実装しない。まず既存3台でbehaviorを変えないことをhost test、
AtomVM compatibility check、実機missionで確認する。

## 影響

3本目のtransport streamを追加する際、Controller transport lifecycleの複製は不要になる。ただしpeer descriptorを1件追加するだけでは
4-node applicationにならない。remote firmware、identity、readiness、probe、metrics、failure isolation、起動順を別途設計する必要がある。

AtomVMの固定7秒distribution setup timerは残る。shared half-duplex busで3 handshakeを同時に成立させられるとは仮定せず、
4台実機ではstandard Modbus Unit 3を先に検証し、その後に3本目のdistribution connectionを試す。

実装中にhostでは利用できる`Map.new/2`がAtomVM v0.7 compatibility checkで未提供と判明したため、map生成は
`Enum.reduce/3`と`Map.put/3`で行う。この互換性境界もexample内に留める。
