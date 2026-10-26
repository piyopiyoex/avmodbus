# Stage 8 recovery-only report

## 目的

Traffic campaignを実行しない復旧試験を、traffic未実行とrecovery失敗に分けて評価する。Stage 8の反復試験で共通利用する
復旧時間、resource、connection eventの集計基盤を先に固定する。

## 変更

`RobotSim.EnduranceReport`へ`traffic`と`recovery`の個別評価を追加した。CLIは既定の`traffic` modeに加えて、次の指定を受け付ける。

```sh
mix run scripts/endurance_report.exs \
  --mode recovery \
  --since HH:MM:SS.mmm \
  --until HH:MM:SS.mmm \
  controller.log drive.log sensors.log
```

`evaluation`は選択したmode、traffic、recovery、3 roleのresource観測、log整合を個別に示す。`recovery_metrics`はhostがserial logへ
付けたtimestampから次の時間を計算する。

- transport readyからrestart開始
- transport readyからapplication recovery確認
- restart開始からremote kernel再起動完了
- remote kernel再起動完了からController再接続

複数deviceのmonotonic timeは比較しない。Timestampがない場合、順序が逆の場合、または必要なeventがない場合は`nil`とする。
複数回の復旧を含むlogはrunごとにtime windowを分ける。

## ホスト検証

`examples/hello_atomvm_modbus_robot/`でformat checkと全testを実行し、130 tests、0 failuresだった。

合成logではtraffic未実行、recovery成功、restart未完了、無効mode、host timestampからの時間計算を検証した。既定の`traffic` modeは
従来どおりtraffic完了を必須とする。

## Stage 7実ログの再集計

Stage 7 deferred restartの保存済み3 role logを、09:59:10–10:07:30の範囲で再集計した。

| 項目 | 結果 |
| --- | --- |
| Report mode / successful | `recovery` / `true` |
| Traffic / recovery | `not_run` / `passed` |
| Resource observation / log | `complete` / `valid` |
| Transport ready → restart started | 33 ms |
| Transport ready → recovery verified | 10,634 ms |
| Restart started → restart succeeded | 212 ms |
| Restart succeeded → remote reconnected | 4,611 ms |
| Global rejection | 0 |
| Controller minimum free heap | 68,824 bytes |
| Sensors minimum free heap watermark | 79,784 bytes |
| Drive minimum free heap watermark | 80,060 bytes |

Connection eventは`restart_deferred`、`transport_resumed`、`transport_ready`、kernel stop / start、`restart_succeeded`、
`remote_reconnected`、`recovery_verified`、`peer_maintained`が各1件で、failure eventとbudget exhaustionは0件だった。

## 判断

- Recovery-only試験をtraffic未実行のまま成功判定できる。
- Stage 7で手計算したtransport readyからprobe成功まで約10.6秒とreport結果が一致した。
- `successful`だけで判断せず、`evaluation`の内訳とraw logを併記する。
- この集計は単一runの証跡を評価するもので、recovery policyの再現性はまだ示さない。

次は同じreport項目をcurrent / deferred policyの各runへ適用し、約120秒・300秒の通信断をclean bootから反復する。
