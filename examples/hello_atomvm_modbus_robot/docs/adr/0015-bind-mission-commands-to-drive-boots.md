# 0015: mission commandをDrive bootへ束縛する

## 状態

採用

## 背景

Driveは同じrequest IDとcommandの直近resultをRAMへ保持し、lost reply後のretryでmovementを再実行しない。しかしDrive rebootでは
rover stateとrequest cacheがともに失われる。従来のsame-ID retryを新しいDrive processへ送ると新規commandとして実行されるため、
旧bootでmovementを実行済みか不明な状況では重複した物理動作に相当する。

永続logがないため、reply受信前にrebootしたcommandが旧bootで実行されたかを新bootから確定することはできない。したがって
自動resumeやexactly-onceを約束せず、曖昧なoutcomeを検出して新bootでの再実行を止める境界が必要である。

## 判断

Drive processは起動ごとに非zeroの32-bit boot IDを生成し、identity requestへ返す。`SensorMission`はmission開始時にboot IDを1回取得し、
movementとfinal statusの全commandを次のguarded application messageで送る。

```elixir
{:robot_guarded_command, reply_to, request_id, expected_boot_id, command}
```

- `expected_boot_id`が現在のDrive bootと一致するときだけ、従来のrequest cacheとstate transitionを使用する
- 同一boot内のlost replyはsame-ID retryでcached resultを取得する
- boot IDが異なる場合はstate transitionを行わず、現在のboot IDを含むerrorを返す
- Controllerは不一致を`{:indeterminate_command, request_id, expected_boot_id, current_boot_id}`へ変換し、missionを停止する

互換性のためunguardedな`{:robot_command, ...}`は残す。guarded recoveryはsensor-driven missionで使用し、AVModbus core、carrier、
FC-100 wire protocolは変更しない。

## 影響

replyを失った実行済みcommandの直後にDriveをrebootしても、retryは新bootでmovementを再実行しない。2026-10-21の3台実機試験では、
request `3061778947`のreplyを破棄してDriveをresetした後、旧boot `717108360`を持つretryを新boot `3388176805`が拒否し、
missionはindeterminate outcomeとして停止した。

これは旧bootでの実行有無を確定せず、rover stateも復元しない。operatorまたは上位applicationが状態を確認して新しいmissionを開始する
必要がある。boot IDはrandomなvolatile IDであり、永続identityやcollision-free namespaceではない。cache eviction後に同じbootで古い
request IDを再利用する場合も保護しない。ControllerとDriveのrolling upgrade保証はなく、guarded missionを使う場合は両方を対応firmwareへ
更新する。
