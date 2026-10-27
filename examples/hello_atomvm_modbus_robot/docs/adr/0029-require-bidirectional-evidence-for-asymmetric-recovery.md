# 0029: 非対称障害の復旧判定には双方向成立の証拠を要求する

## 状態

採用

## 背景

Stage 7–8のdeferred restartは、ServerがFC-100 requestを再び受理したことをtransport復帰のsignalとして使う。Responseだけが失われる
非対称障害ではrequest受理が継続するため、activity gapと`transport_ready`が発生しない。

Stage 9の3台実機比較では、current policyは2 / 2でrestart後に復旧した一方、deferred policyは2 / 2でrestartを保留し、
response復帰後180秒以内にdistributionが復旧しなかった。

## 判断

- `request_accepted`だけで非対称障害からのtransport復帰を判定しない。
- `response_returned`もControllerへの到達を保証しないため、単独ではrestart解放条件にしない。
- 将来signalを追加する場合は、Controllerによるresponse受信または同等のcarrier-level ACK進行を確認できることを要件とする。
- Stage 9ではrecovery policyとFC-100 wire protocolを変更しない。
- Current policyを既定、deferred policyをopt-inのまま維持する。

## 影響

- Deferred policyは長時間の双方向通信断には有効だが、非対称response blackoutには使用できない。
- 双方向signalの設計では、diagnostic log、Server adapterの返却、UART送信、Controller受信の境界を区別する。
- AVModbus coreへ実験固有のrecovery機構を追加しない。
- 実測条件と結果は[Stage 9実機比較](../worklog/2026-10-27-stage-9-asymmetric-response-blackout.md)を正とする。
