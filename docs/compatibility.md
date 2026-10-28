# 動作確認済みの構成

この表には、**実際に試した組み合わせ**だけを記録しています。
「未検証」は「動作しない」という意味ではありません。

## 確認済み

| 接続するもの | 通信方式 | 機器・バージョン | 確認できたこと |
| --- | --- | --- | --- |
| AVModbus ↔ AVModbus | RTU / RS485 | XIAO ESP32-C5 × 2、HW-519 × 2、AtomVM `v0.7.0-beta.0+git.8d3e051` および `0.7.0-beta.1+git.a1069573` | 2026-10-10 に 5 分間・1,623 件成功、失敗 0。2026-10-28 に `v0.1.0` 候補で 20 種類の要求を 3 cycles、計 60 件実行し、失敗 0 |
| AtomVM `serial_dist` ↔ `serial_dist` | AVModbus custom FC-100 carrier / RTU / RS485 | XIAO ESP32-C5 × 2、HW-519 × 2、AtomVM `v0.7.0-beta.0+git.8d3e051` | 2026-10-15〜16 に genuine distribution handshake、remote process ping / pong、512-byte payload の 30 往復、96-byte chunk と 9,600 baud での 4 KiB payload の3回連続往復、115,200 baud での 4 KiB payload の 1 往復、確立済み 4 KiB 転送中の Server reboot recovery、FC-100 peer readiness gateを確認。さらにAtomVM local patch `735841ba`ではreadiness後の40-response handshake faultからapplication retryで復旧し、旧boot libraryとの実機A/Bを確認 |
| AVModbus ↔ `pymodbus` | TCP / RTU / ASCII | ホスト上の TCP・仮想シリアル、`pymodbus` 3.15.0 | Client / Server の両方向でテスト |
| AVModbus ↔ `libmodbus` | TCP / RTU | ホスト上の TCP・仮想シリアル、`libmodbus` 3.1.11 | Client / Server の両方向でテスト |

外部実装とのテストは 2026-10-14 に固定 seed 2 種類でローカル実行しました。
**GitHub Actions 上での成功は、この記録だけでは確認できません。**
ホスト上の仮想シリアル試験は、実機の RS485 試験とは区別しています。
2026-10-28 の RTU workflow は 9,600 baud、8N1、Unit ID `1`、20 ms gap で実施しました。
AtomVM `a1069573` は `18b35870` に distribution tick 用の local patch を加えた版です。
この patch は通常の Modbus RTU workflow では使用しません。
3台構成の standard Modbus RTU multidrop の実機結果は
[仮想ロボットの worklog](https://github.com/piyopiyoex/avmodbus/tree/v0.1.0/examples/hello_atomvm_modbus_robot/docs/worklog)
に記録しています。これは一般的な機器互換性の保証ではありません。

`serial_dist` の行は、AVModbus の custom Function Code API を利用した
[standalone experiment](https://github.com/piyopiyoex/avmodbus/blob/v0.1.0/examples/hello_atomvm_modbus_disterl/README.md) の結果です。
distributed Erlang carrier は AVModbus core の機能ではなく、production-ready な互換性を
保証するものではありません。詳細な測定値と条件は
[実験の worklog](https://github.com/piyopiyoex/avmodbus/blob/v0.1.0/examples/hello_atomvm_modbus_disterl/docs/worklog/README.md) を参照してください。

## まだ確認していない構成

- HW-519 以外の RS485 トランシーバーや USB-RS485 アダプター
- 市販の Modbus RTU 機器
- 4 台以上をつないだ RS485 のマルチドロップ構成（3台は仮想ロボットの standalone example で検証済み）
- 別の AtomVM 対応基板や新しいファームウェア

## 新しい結果を追加するとき

日付、AVModbus・AtomVM のバージョン、機器、配線、通信設定、試した操作、
成功・失敗の件数、再現手順を記録してください。
メモリ測定やエラーログがあれば一緒に残します。
実験結果の背景は
[開発記録](https://github.com/piyopiyoex/avmodbus/blob/main/docs/development/worklog.md)
を参照してください。
