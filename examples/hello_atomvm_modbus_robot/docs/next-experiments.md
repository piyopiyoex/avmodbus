# 次の実験: scalable multinode model

3台（Controller 1台、2 remote peers）のphysical integration baselineを維持し、それ以上のremote peer数はhost上の
deterministic modelで検証します。
deviceを1台ずつ追加することはroadmapの完了条件にしません。判断の背景は
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

## 次のtest matrix

最初はremote peer数`1, 2, 3, 8, 32`を対象にします。random testを追加する場合も、失敗を再現できるseedを
必ず記録します。

| 観点 | 入力 | 確認内容 |
| --- | --- | --- |
| descriptor | role、Unit ID、node identity | 欠落、範囲外、重複を拒否し、入力順を保持する |
| scheduling | N peer、複数round | 各peerが1 roundに1回だけtokenを受け、順序と公平性が崩れない |
| slow peer | 1 peerだけ完了を遅延 | 同時transactionを発生させず、遅延の影響を測定する |
| failed peer | timeout / disconnect | 正常peerのdeadlineと進行を維持できるpolicyを比較する |
| overload | producer rate > drain rate | queue上限、backpressure、drop / retry境界を確認する |
| recovery | session change / reboot | 古いstateを破棄し、application retryの必要範囲を確認する |
| resources | remote peer数とqueue設定 | adapter、queue、mailbox、推定heapの増加を記録する |

wire上のModbus transactionは、remote peer数にかかわらず1個のClientが直列化する前提です。host modelでparallel transactionを
許可してはいけません。

## 成功条件

- 同じ条件とseedで結果を再現できる。
- remote peer数を増やしても各peerのdelivery / scheduling結果をrole別に説明できる。
- failureを注入したpeerと正常peerの影響を分離して記録できる。
- queue、timeout、retry、resource budgetに明示的な上限がある。
- 3台実測とhost modelの値を混同せず、simulation、推定、実測を区別する。

## 停止条件

- OOM、unbounded queue、再現不能なraceを観測した場合はremote peer数を増やさず原因を固定する。
- modelのためだけにAVModbus coreへdistribution固有APIを追加しない。
- AtomVM runtimeの挙動を仮定で埋めない。host modelで答えられない点は制約として残す。

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
