# 変更履歴

## Unreleased

## 0.1.0

初回公開版。AtomVM を対象とした汎用 Modbus ライブラリを提供します。

### 追加

- Modbus RTU / ASCII / TCP の Client・Server
- Coil・Discrete Input・Input Register・Holding Register の読み書き
- 診断、デバイス情報、UART、タイムアウト、再接続、読み取り処理のリトライ
- `pymodbus`・`libmodbus` との相互運用テストと ESP32-C5 実機検証

### 改善

- TCP 接続単位の受信バッファー、終了処理、リソース管理を強化
- AtomVM 上でのメモリ使用量とファームウェアサイズの計測手順を整備

### 実験（Hex パッケージには含まれない）

- [distributed Erlang over Modbus RTU](https://github.com/piyopiyoex/avmodbus/tree/v0.1.0/examples/hello_atomvm_modbus_disterl)
  で genuine distribution、session recovery を検証
- [分散Erlang仮想ロボット](https://github.com/piyopiyoex/avmodbus/tree/v0.1.0/examples/hello_atomvm_modbus_robot)
  で3台の ESP32-C5 と共有 RS485 bus を使う実験を実施
- いずれの experimental carrier も AVModbus の public API または production support の対象外
