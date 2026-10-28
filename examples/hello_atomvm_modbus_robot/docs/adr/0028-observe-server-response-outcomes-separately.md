# 0028: Serverのresponse処理をtransport activityと分けて観測する

## 状態

採用

## 背景

Stage 8のtransport activity observerは、Serverが有効なFC-100 requestを受理した時点を観測する。Requestが届き続け、responseだけが
失われる非対称障害ではactivity gapが発生せず、response経路の復旧を判定できない。

## 判断

- `DisterlProbe.ModbusUART`に任意の`exchange_observer`を追加する。
- Request受理、response返却、faultによるresponse破棄を別eventにする。
- 同じadapter内のeventを`exchange_id`で対応付ける。
- `response_returned`はAVModbus Serverへ値を返したことだけを表し、物理送信やController到達を保証しない。
- Controller到達はClient transactionの結果で別に確認する。
- Robot exampleでは`ROBOT_MULTINODE_EXCHANGE_TRACE`を明示した場合だけ記録する。
- Robot exampleは破棄対象requestとfault終了後の最初のresponseだけを出力し、通常pollの大量出力を避ける。

## 影響

- Recovery policy、timeout、restart budgetは変更しない。
- Observerは診断時のmessageとconsole出力を増やすため、既定値では無効にする。
- Adapter restartで`exchange_id`は1へ戻るため、connection IDやsession IDと組み合わせて読む。
- AVModbus coreとFC-100 wire protocolは変更しない。
