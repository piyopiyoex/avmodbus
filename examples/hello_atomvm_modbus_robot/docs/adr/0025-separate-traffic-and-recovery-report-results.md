# 0025: trafficとrecoveryの成功判定を分離する

## 状態

採用

## 背景

`RobotSim.EnduranceReport`の`successful`はtraffic完了を必須としていた。そのため、Stage 7のようにtraffic campaignを実行せず、
distribution recoveryだけを検証したlogは、復旧に成功していても`successful: false`となった。

trafficとrecoveryでは必須eventが異なる。一方を実行していないことと、実行して失敗したことを同じ結果にすると、反復試験の
成功率や失敗理由を正しく集計できない。

## 判断

- reportに`traffic`と`recovery`の個別評価を追加し、`:passed`、`:failed`、`:not_run`を区別する。
- `mode: :traffic`を既定値として従来の成功判定を維持する。
- `mode: :recovery`では、復旧確認、正常peerの維持、restart lifecycle、resource観測、log整合を成功条件にする。
- `--mode traffic|recovery`でCLIから評価対象を明示する。
- host timestampがある場合だけ、transport ready、restart、reconnect、application probe間の時間を集計する。
- raw serial logを実測の正とし、reportは観測されなかったeventを推定しない。

## 影響

- recovery-only試験をtraffic未実行のまま成功・失敗判定できる。
- `successful`は選択したmodeの総合結果となり、内訳は`evaluation`で確認できる。
- 複数deviceの`at_ms`は比較せず、hostが各serial logへ付けた同日内のtimestampから経過時間を求める。
- timestampがない場合や順序が逆の場合、該当する経過時間は`nil`となる。
- 成功判定は対象window内の証跡だけを表し、任意の通信断からの復旧やmemory stabilityを保証しない。
- Firmware、AVModbus core、FC-100 wire protocolは変更しない。
