# ロードマップ

host-only rover から3台の genuine distributed Erlang application までを実証し、起動、通信断、
resource budget、application recovery の調査を Stage 11 まで完了しました。

現在の実行方法は [サンプル README](../README.md)、実測値は [検証結果](worklog/README.md)、
保証外の範囲は [既知の制約](limitations.md) を正とします。

## 現在地

| Stage | 状態 | 結果 |
| ---: | --- | --- |
| 0 | 完了 | pure function による host-only rover |
| 1 | 完了 | 2-node mission、request ID、Drive reboot 境界 |
| 2 | 完了 | 3-device standard Modbus multidrop |
| 3 | 実証完了 | Controller から2本の distribution connection、relay、独立 reboot |
| 4 | 完了 | virtual sensors、adaptive mission、reply-loss retry、boot guard |
| 5 | 完了 | 1〜32 remote peers の host model と global queue budget |
| 6 | 完了 | 全6起動順序、初回接続復旧、約1時間の endurance |
| 7 | 完了 | 長時間通信断後に transport 復帰を待つ restart policy |
| 8 | 完了 | current 0 / 4、deferred 4 / 4 の反復比較 |
| 9 | 完了 | 非対称 response blackout と双方向 signal の必要性 |
| 10 | 完了 | `net_kernel` stop / start と setup failure の責任境界 |
| 11 | 完了 | mission abort 後の fresh sample と非変更 status probe |

## 次の実験へ進む条件

- 3台構成で新しい failure model または runtime 変更を検証する具体的な仮説がある
- host model では確認できない UART / RS485 timing または memory の疑問がある
- 成功条件、停止条件、測定項目を実験前に定義できる

4台目による3本目の distribution connection は、上記を満たす場合だけ実施します。
device 数を増やすこと自体は milestone にしません。

## 維持する方針

- AVModbus core と FC-100 wire protocol は変更しない
- 3台を physical baseline とし、scale はまず host model で調べる
- current recovery policy を既定、deferred policy を opt-in とする
- transport reconnect と application workload の再開を区別する
- durable state、自動 mission resume、production robotics は対象外とする
- AtomVM runtime の問題はこの repository に再現条件と制約を記録する
