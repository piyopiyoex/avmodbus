# 0003: 既存 example の experimental carrier を再利用する

- Status: accepted
- Date: 2026-10-18

## 背景

Stage 1 は `hello_atomvm_modbus_disterl` で検証した FC-100 channel と virtual UART を必要とします。source を robot
example へ複製すると、session recovery、queue 上限、startup mitigation の修正を 2 箇所で維持することになります。
一方、この carrier は proprietary protocol であり、lifecycle contract も production API として固定していません。

## 判断

Robot example は `../hello_atomvm_modbus_disterl` を local path dependency とし、
`DisterlProbe.ModbusUART` を `serial_dist` の `uart_module` として直接利用します。Robot 固有の node name、application
protocol、startup、mission execution は `RobotSim` namespace に置きます。

現時点では carrier を AVModbus core または独立 package へ移しません。transport source は複製せず、各 example に必要な
compile-time configuration と application bootstrap だけを個別に持ちます。

## 影響

- 既存 carrier の sequence / ACK、session recovery、bounded queue、peer readiness をそのまま利用できます。
- AVModbus core と既存 distributed Erlang example の source を変更しません。
- Robot example は別 example の internal namespace に依存するため、安定した public API ではありません。
- dependency 全体を含むため、専用 package より PackBEAM size が大きくなる可能性があります。
- 2-node robot の実機結果と 3-node 設計で再利用 API が明確になった場合に、example-shared package を再検討します。
