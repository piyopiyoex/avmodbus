# 開発記録

このページには、**将来の開発で判断材料になる結果**を残します。
日々の細かい実装履歴は Git のコミット履歴で確認できます。
利用方法は [README](../../README.md)、現在の課題は [ロードマップ](../roadmap.md) を参照してください。

## 主な開発の流れ

| 日付 | 取り組んだこと |
| --- | --- |
| 2026-10-07 | 既存の実験コードから Modbus 処理を分離し、PDU・RTU・CRC16 の実装を開始 |
| 2026-10-08 | Server、メモリ上のデータ領域、再接続処理を追加。プロジェクト名を AVModbus に統一 |
| 2026-10-09 | ASCII・TCP の Client / Server、Supervisor 対応、外部実装との相互運用テストを整備 |
| 2026-10-10〜11 | RS485 実機通信、長時間テスト、メモリ計測、TCP リソース上限の調査 |
| 2026-10-12〜13 | UART の受信データ欠落対策、Serial Transport の整理、待機キューとタイムアウト管理の強化 |
| 2026-10-13〜14 | TCP 接続・handler の終了処理、受信バッファー制限、負荷テスト、外部実装との CI を強化 |
| 2026-10-15〜16 | custom FC-100 carrier を使い、Modbus RTU 上の AtomVM distributed Erlang を実機検証 |
| 2026-10-28 | `v0.1.0` Hex release candidate の package、docs、host test、AtomVM build を検証 |

## v0.1.0 release candidate

2026-10-28 に、初回 Hex 公開候補を次の範囲で確認しました。

- `mix format --check-formatted`、Python 補助 script 3 tests、ExUnit 228 tests が成功
- coverage は 84.75% で、設定した 80% threshold を満たした
- `mix docs --warnings-as-errors` が成功
- 通常、workflow probe、resource probe の `mix atomvm.check` が成功
- production AVM は 147,536 / 147,736 bytes で size budget 内（残り 200 bytes）
- `mix hex.build` と unpack が成功し、package は約 103 KiB だった
- 展開 package を別 Mix application から path dependency として compile し、RTU encode / decode を実行できた
- `mix hex.publish --dry-run --yes` が成功し、package と docs が公開されないことを確認した
- Hex 認証 user は `mnishiguchi`、`avmodbus` という公開 package は未登録だった

実機では、Drive を Unit ID `1` の RTU Server、Controller を workflow Client として、
XIAO ESP32-C5 と HW-519 を共有 RS485 bus へ接続しました。Sensors（Unit ID `2`）も同じ bus へ
接続したまま試験しました。通信条件は 9,600 baud、8N1、D4 / GPIO23 TX、D5 / GPIO24 RX、
20 ms gap、20 ms UART idle timeout です。

- Controller: USB serial `38:44:BE:A5:05:14`
- Drive: USB serial `38:44:BE:A5:04:DC`
- Sensors: USB serial `10:BD:A3:CF:09:04`

Controller と Drive の runtime はいずれも AtomVM `0.7.0-beta.1+git.a1069573` でした。
これは upstream `release-0.7` の `18b35870` に distribution tick 用の local patch を加えた版です。
patch はこの通常 RTU workflow の処理には関与しません。

20 種類の要求を 3 cycles、計 60 件実行し、`modbus_workflow result=ok` を確認しました。
最小 response-to-next-write interval は 43 ms、broadcast turnaround は 136 ms、
request は最小 136 ms、最大 218 ms、平均 165 ms、総時間は 9,918 ms でした。
欠損、timeout、想定外の応答、Unit ID `2` の接続による干渉は観測しませんでした。

リリース対象 commit の CI と外部実装との相互運用は release PR で再確認する。
実際の publish、tag push、GitHub Release 公開はレビュー承認後に手動で行う。

## 実験から得た重要な知見

### 1. UART の受信間隔は、機器で確認してから変更する

**環境:** XIAO ESP32-C5 × 2、HW-519 × 2、AtomVM `v0.7.0-beta.0+git.8d3e051`。

AtomVM の UART を短い間隔で読み直すと、受信データが欠落することがありました。
そのため専用の読み取りプロセスで継続受信し、隣接するデータをまとめています。

2026-10-13 の RTU 実機試験（各 3 回、合計 60 request）では次の結果でした。

| 通信速度 | RX idle timeout | 結果 | Request 所要時間（最小 / 平均 / 最大） |
| ---: | ---: | --- | --- |
| 9,600 baud | 20 ms | 60 / 60 成功 | 136 / 179 / 233 ms |
| 9,600 baud | 10 ms | 5 件目でタイムアウト | — |
| 115,200 baud | 20 ms | 60 / 60 成功 | 134 / 144 / 164 ms |

**判断:** 現在の構成では 20 ms を維持します。これは UART の受信処理の設定で、
Modbus RTU のフレーム間隔とは別です。短縮する場合は、長いフレームを含む実機試験を再実行してください。
詳細な手順は [実機の追加検証](hardware-tests.md) にあります。

### 2. RS485 の送信前には余裕が必要だった

同じ実機構成の workflow test では、プロトコルから計算した約 5 ms の送信間隔で途中失敗が起き、
10 ms でもタイムアウトが再現しました。20 ms では 3 回・60 request が成功しました。

**判断:** 検証用 workflow は 20 ms を既定値とします。
ほかのトランシーバーや UART でもこの値が必要とは限りません。

### 3. TCP のリソース上限は AtomVM 側でも調べる

ESP32-C5 で接続負荷を増やした際、復旧可能なエラーが Elixir に返る前にランタイムが停止する現象を確認しました。
一方、通常の負荷試験ではプロセス数と空きメモリが回復することを確認しています。
`event_queue` の警告だけでメモリリークと判断することはできません。

**判断:** サンプルの計測は確認済みの 1〜4 接続に制限します。
4 接続が常に安全であるという意味ではありません。
再現方法と切り分けは [TCP リソース調査記録](atomvm-tcp-investigation.md) に残しています。

### 4. メモリの計測にはウォームアップが必要だった

ホストでの 1 時間の連続テストでは、起動直後のメモリ使用量と、稼働が安定した後の使用量に差がありました。
固定サイズのイベントログが埋まる前後の差だったため、ウォームアップ後を基準に計測するように変更しました。

**判断:** メモリ使用量の増加を調べる際は、同じ条件で十分にウォームアップし、
起動直後との差だけでリークと判断しないようにします。

### 5. TCP の接続終了は、処理中の handler も対象にする

処理の遅い handler が残らないよう、接続の終了・強制終了・eviction を回帰テストに追加しました。
リスナーによる代替 cleanup と、終了待ちに上限を設けた設計にしています。
受信バッファー上限の `max_buffer` は、接続全体のメモリ使用量を厳密には制限しません。

**判断:** TCP の受信処理と handler の寿命を、接続ごとに管理します。
詳細は [ADR 0007](../adr/0007-isolate-modbus-tcp-connections.md) を参照してください。

### 6. Custom Function Code は `serial_dist` の carrier primitive にできる

**環境:** XIAO ESP32-C5 × 2、HW-519 × 2、AtomVM
`v0.7.0-beta.0+git.8d3e051`、2-wire RS485。

custom Function Code `100` の request / response に polling、sequence / ACK、session ID を
重ね、その上の virtual UART adapter を AtomVM の `serial_dist` へ接続しました。genuine
distribution handshake と remote process messaging に加え、512-byte payload の 30 往復を
223.327 秒、error と pong timeout なしで完了しました。片側または両側の再起動後の再同期も
確認しています。115,200 baud の follow-up では 512-byte payload の 30 往復を 99.877 秒で完了し、
4 KiB payload の 1 往復も 22.617 秒で完了しました。同じ 4 KiB payload は 9,600 baud でも
3回の往復を連続実行し、RTT min / average / max 33.817 / 34.743 / 36.594 秒、timeout 0 で完了しました。
さらに、確立済み connection の2回目の 4 KiB upload を最初の 96-byte chunk で Server reboot により中断し、
session resynchronization と1回の pong timeout を経て同じ message を再送、検証できました。

**判断:** AVModbus の custom function support は application-specific carrier の実装に利用できます。
ただし、今回の polling protocol、stream adaptation、recovery logic は Modbus library の一般機能では
ありません。AVModbus core を変更せず、[standalone example](https://github.com/piyopiyoex/avmodbus/blob/v0.1.0/examples/hello_atomvm_modbus_disterl/README.md)
内で実験を継続します。条件、測定値、残る制約は
[実験の worklog](https://github.com/piyopiyoex/avmodbus/blob/v0.1.0/examples/hello_atomvm_modbus_disterl/docs/worklog/README.md) に記録しています。

## 検証記録を探す

| 内容 | 記録場所 |
| --- | --- |
| RTU / RS485 の実機試験、設定と検証手順 | [実機の追加検証](hardware-tests.md) |
| 実機のメモリ使用量、TCP loopback、`.avm` の測定値 | [リソース計測](resource-measurements.md) |
| TCP 高負荷時の調査と再現条件 | [TCP リソース調査記録](atomvm-tcp-investigation.md) |
| `pymodbus` / `libmodbus` と動作確認した組み合わせ | [互換性表](../compatibility.md) |
| Modbus RTU 上の distributed Erlang、性能、復旧試験 | [実験の worklog](https://github.com/piyopiyoex/avmodbus/blob/v0.1.0/examples/hello_atomvm_modbus_disterl/docs/worklog/README.md) |
| 将来も守りたい設計上の判断 | [ADR 一覧](../adr/README.md) |

## 新しい実験を記録するとき

結果が今後の設計・不具合調査に役立つ場合は、**日付、目的、機器と AtomVM のバージョン、
手順、成功・失敗の結果、そこから採用した方針**を記録してください。
未確認の推測は、確認済みの結果とは分けて書きます。
