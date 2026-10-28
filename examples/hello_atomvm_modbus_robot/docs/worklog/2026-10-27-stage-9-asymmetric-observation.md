# Stage 9 非対称障害の観測基盤

## 目的

Response blackout中もrequestを受信し続けるremoteで、request受理とresponse outcomeを区別して記録する。

## 変更

- `DisterlProbe.ModbusUART`へopt-inの`exchange_observer`を追加した。
- `request_accepted`、`response_returned`、`response_dropped`を同じ`exchange_id`で通知する。
- Robot exampleへ`ROBOT_MULTINODE_EXCHANGE_TRACE`と`modbus_robot_exchange`形式のlogを追加した。
- 観測処理はreadiness待ちと接続済みloopの両方で継続する。
- Host reportへrole別のexchange event件数を追加した。

`response_returned`はadapterがAVModbus Serverへresponseを返した境界であり、Controllerへの物理到達ではない。
Controller側のtransaction結果を併用する。

## ホスト検証

```text
hello_atomvm_modbus_disterl: 83 tests, 0 failures
hello_atomvm_modbus_robot:  136 tests, 0 failures
```

Carrier testでは正常responseとfaultで破棄したresponseの両方について、requestとresponse outcomeが同じ`exchange_id`になることを
確認した。Robot testではevent名、field順、無効時に出力しないことを確認した。

Current policyのController / Drive / Sensorsと、Deferred policyのSensorsについて`mix atomvm.check`と
`mix atomvm.packbeam`に成功した。`No avm_deps directory found`はstandard libraryをAtomVMのlib partitionへ導入済みの構成での
想定内messageである。

## 実機検証

Current / deferred各2 runsの3台実機比較を完了した。実測値と判断は
[Stage 9実機比較](2026-10-27-stage-9-asymmetric-response-blackout.md)を参照する。

実機条件は[Stage 9試験計画](../stage-9-asymmetric-response-blackout.md)を正とする。
