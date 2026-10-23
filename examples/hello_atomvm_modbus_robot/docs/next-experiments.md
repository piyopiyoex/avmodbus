# Scalable multinode host model

3台（Controller 1台、2 remote peers）のphysical integration baselineを維持し、それ以上のremote peer数はhost上の
deterministic modelで検証します。
deviceを1台ずつ追加することはroadmapの完了条件にしません。2026-10-24に計画したtest matrixを完了しました。
判断の背景は
[ADR 0020](adr/0020-model-scale-on-host-instead-of-adding-devices.md)を参照してください。

過去のconcurrent traffic、障害復旧、長時間測定の数値は[作業記録](worklog/README.md)へ集約しています。

## Baseline

現在の3台構成では次を確認済みです。

- shared Modbus Client上の2本のgenuine distributed Erlang connection
- 32+32、64+64、256+256 flow-controlled traffic
- round-robin pollingと単一peer branch障害中の正常peer継続
- readiness lease、remote-side restart、stale connectionの境界
- mission commandのboot guardとindeterminate outcome
- 最新AtomVM v0.7 snapshot + local tick patchでのmissionとconcurrent traffic
- peer descriptor list駆動のController transport setup

このbaselineは4台以上のphysical distributionを保証しません。

## 完了したtest matrix

remote peer数`1, 2, 3, 8, 32`を対象にしました。randomnessは使用していません。

| 観点 | 入力 | 結果 |
| --- | --- | --- |
| descriptor | role、Unit ID、node identity | 欠落、範囲外、重複を拒否し、入力順を保持した |
| scheduling | 1、2、3、8、32 peers、4 rounds | 各peerが4 pollsを受け、max active transactionは1だった |
| slow peer | 3 peersの1 peerを50 ms | poll回数は各3、elapsedは156 msとなり遅延はcycleへ加算された |
| failed peer | 8 peersの1 peerを4回timeout | 正常7 peersは各4 successes、全体は8,028 msだった |
| overload | arrival 2、drain 1、queue limit 3 | max queue 3、remaining 2、rejected 2でboundedだった |
| recovery | round 3でsession change | stale 2件を破棄し、new sessionで2件をdeliveryした |
| resources | 1、2、3、8、32 peers | configured limitとobserved-scale projectionを分離し、AtomVM heap推定はunknownとした |

wire上のModbus transactionは、remote peer数にかかわらず1個のClientが直列化する前提です。host modelでparallel transactionを
許可してはいけません。

## 完了条件

- randomnessを使わず、同じ条件で結果を再現できる。
- remote peer数を増やしても各peerのdelivery / scheduling結果をrole別に説明できる。
- failureを注入したpeerと正常peerの影響を分離して記録できる。
- queue、timeout、retry、resource budgetに明示的な上限がある。
- 3台実測とhost modelの値を混同せず、simulation、推定、実測を区別する。

上記はhost modelのfocused test 11件、実`PollScheduler`のfocused test 4件、再現scriptで確認した。詳細は
[host model worklog](worklog/2026-10-24-scalable-multinode-host-model.md)を参照する。

## 得られた制約

- poll fairnessはlatency fairnessを意味せず、slow / failed peerのservice timeは全peerのcycleへ影響する。
- bounded queueはrejection後のdeliveryを保証せず、session changeはstale queueを破棄する。
- 32 peersのconfigured payload limit 262,144 bytesは3台実測のminimum free heap 68,848 bytesを超える。
- host modelはAtomVM runtime、physical bus、3本目以上のdistribution handshakeを保証しない。

## Hardwareの扱い

3台はRS485 wiring、half-duplex transaction、実UART、AtomVM heapを含むintegration baselineとして使います。追加deviceは、次のような
具体的な仮説がある場合だけspot checkに使います。

- transceiver loadingやterminationがremote peer数で変わる
- 3本以上のdistribution handshakeが固定setup timerに収まるか
- host推定と実AtomVM heapの差が大きい
- 実UART turnaroundがmodelの前提を崩す

単にNを1増やすだけの試験は行いません。

## Source of truth

- 現在の実行方法: [サンプルREADME](../README.md)
- Stageと完了条件: [ロードマップ](roadmap.md)
- 保証しない範囲: [既知の制約](limitations.md)
- 設計判断: [ADR](adr/README.md)
- 実測値と時系列: [作業記録](worklog/README.md)
