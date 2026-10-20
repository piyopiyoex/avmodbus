# Modbus RTU distributed Erlang で動かす仮想ロボット（実験）

AtomVM の distributed Erlang over Modbus RTU を、通信確認だけでなく分散 application に利用するための
独立した実験用 Mix project です。ロボットは software 上で再現するため、motor、sensor、車体は必要ありません。

現在は **Stage 0: host 上の rover simulation**、**Stage 1: 2-node distributed robot**、および
**Stage 2: 3-device standard Modbus multidrop** を完了し、**Stage 3: 3-node distributed Erlang** の基本疎通と
Controller-mediated sensor relay、**Stage 4: sensor-driven mission** まで実証しています。2 台構成では genuine distributed Erlang を確立し、
Controller から Drive の registered process へ command を送り、最終 state `(100, 50, 90°)` を確認しました。3 台構成では
1 台の Controller が shared RS485 bus 上の Drive Unit 1 と Sensors Unit 2 を順番に poll し、115,200 baud では
両 remote node と同時に genuine distribution connection を確立しました。既存の
[`hello_atomvm_modbus_disterl`](../hello_atomvm_modbus_disterl/README.md) を local path dependency として再利用し、
128-byte payload の 60 application round trip、3 role の独立 reboot recovery、および
`Sensors -> Controller -> Drive` の virtual sensor sample 転送と obstacle 回避判断も確認しています。AVModbus core と既存 example の
protocol design は変更していません。follow-up では、共有 client を現在の AVModbus managed handle で渡すための互換性修正を
既存 carrier に加えています。

## 現在できること

- 整数 millimetre 単位の X/Y 座標と 4 方向の heading を保持する
- 指定距離だけ前進する
- 90° 単位で左右へ旋回する
- 現在の rover state を取得する
- 同じ初期状態と command 列から常に同じ結果を得る
- deterministic demonstration mission を host test で検証する
- request ID 付き command を drive process へ送り、timeout 時に同じ ID で retry する
- 直近の同一 request を再実行せず、cache 済み result を返す
- 2 台の AtomVM node 間で reference mission を remote 実行する
- Controller が final status を期待値と比較し、不一致を mission failure として検出する
- standard Modbus RTU mode で Drive と Sensors を同じ bus 上から順番に poll する
- 1 本の physical UART 上に Unit ごとの FC-100 stream を作り、Drive / Sensors と同時に remote message を交換する
- Drive / Sensors への payload echo を交互順で継続し、role 別の RTT と失敗数を集計する
- payload echo の進行中に remote を再起動し、新 session へ同じ idempotent probe を再送する
- deterministic な virtual distance / battery sample を Sensors node で生成する
- Controller が Sensors から受け取った sample を検証し、Drive へ中継して ACK を確認する
- distance と battery に基づいて Controller が前進、右旋回、位置保持を選ぶ
- 3 台の実機で `forward -> forward -> right turn` の adaptive mission を実行する
- role ごとの readiness lease で Drive / Sensors の停止を検出し、復帰後に両 connection を再確認する
- Drive / Sensors の独立 producer から同時に logical message を送り、role 別 delivery と公平性を集計する

各 Stage の進捗と完了条件は [ロードマップ](docs/roadmap.md) を参照してください。

## Host で実行する

repository root から次を実行します。

```sh
cd examples/hello_atomvm_modbus_robot
mise install
mix format --check-formatted
mix test
mix run -e 'IO.inspect(RobotSim.demo())'
```

最後の command は次を出力します。

```elixir
{:ok, %RobotSim.Rover{x_mm: 100, y_mm: 50, heading_deg: 90}}
```

## 座標と heading

初期位置を `(0, 0)`、初期 heading を `0°` とします。`0°` は `+X` 方向です。heading は右旋回、つまり
clockwise に増加します。この規則では `90°` が `+Y` 方向です。

| heading | 前進時に変化する座標 |
| ---: | --- |
| `0°` | `x += distance` |
| `90°` | `y += distance` |
| `180°` | `x -= distance` |
| `270°` | `y -= distance` |

これは地理上の方位角や、角度が counterclockwise に増える通常の Cartesian plane を表す規則ではありません。
reference mission の「右へ 90° 旋回した後に `+Y` へ進む」という期待値を曖昧なく表すための規則です。
判断理由は [ADR 0001](docs/adr/0001-use-clockwise-heading-from-positive-x.md) に記録しています。

## Command

`RobotSim.Rover.execute/2` は rover state と command を受け取り、新しい state を返す pure function です。

| command | 意味 |
| --- | --- |
| `{:forward, distance_mm}` | 正の整数 millimetre だけ前進する |
| `{:turn, :right, degrees}` | 90° の倍数だけ右旋回する |
| `{:turn, :left, degrees}` | 90° の倍数だけ左旋回する |
| `:status` | state を変更せず現在値を返す |

不正な command は `{:error, :invalid_command}` を返します。pure rover 自体は request ID や retry を扱わず、
process / protocol layer から独立しています。Rover state 自体に時間経過、速度、battery、obstacle は持たせず、virtual sensor と
navigation policy は別 module に分離しています。

## Stage 1 application protocol の host test

`RobotSim.Drive` は rover state を所有し、`RobotSim.Controller` から次の message を受け取ります。

```elixir
{:robot_command, reply_to, request_id, rover_command}
{:robot_reply, request_id, result}
```

host 上では次のように reference mission を実行できます。

```elixir
{:ok, drive} = RobotSim.Drive.start_link()
RobotSim.Controller.demo(drive)
```

Controller は timeout 時に同じ `request_id` で retry します。Drive は default で直近 32 件の
`{request_id, command, result}` を保持し、同一 request には cache 済み result を返します。同じ ID を別の
command に使うと `{:error, :request_id_conflict}` を返します。

この仕組みは lost reply による直近 command の重複実行を防ぎますが、durable exactly-once ではありません。
Drive の reboot または cache eviction 後は履歴が残らないため、Stage 1 の実機試験では controller reconciliation と
in-flight command の扱いを別途検証しました。transport は再接続できましたが、reboot 後の Drive state は復元されず、
Controller が final state の不一致を mission failure として検出しました。`Controller.demo/2` の default request ID は
fresh Drive 向けです。同じ
Drive で別の mission を開始する場合は、以前と重ならない `:first_request_id` を指定する必要があります。判断は
[ADR 0002](docs/adr/0002-deduplicate-retries-with-request-ids.md)、実機結果は
[Drive reboot worklog](docs/worklog/2026-10-18-stage-1-drive-reboot.md) に記録しています。

## Reference mission

```text
開始: (0, 0), heading 0°

100 mm 前進
右へ 90° 旋回
50 mm 前進

結果: (100, 50), heading 90°
```

Elixir では次の command 列です。

```elixir
[
  {:forward, 100},
  {:turn, :right, 90},
  {:forward, 50}
]
```

## 目標アーキテクチャ

```text
  controller@modbus.local       Modbus RTU Client / bus owner
            |
      shared RS485 bus
       /           \
 drive@modbus.local       sensors@modbus.local
  Server Unit 1             Server Unit 2
  virtual movement          virtual sensors
```

Stage 1 では `controller` と `drive` の 2 node で distribution を検証しました。Stage 2 では 3 台を同じ bus に接続して
standard Modbus RTU multidrop を検証しました。Stage 3 では Controller から Drive / Sensors への 2 本の distribution
connection を同時に確立しています。Drive と Sensors の直接 connection は作らず、Server 間の application data は
Controller が中継します。

## Stage 1 の build と実機実行

Stage 1 は既存 example を local path dependency とし、`DisterlProbe.ModbusUART` をそのまま利用します。FC-100
protocol、session、queue、virtual UART source は複製しません。この依存関係は experimental example 間の暫定境界であり、
AVModbus の public API ではありません。詳細は
[ADR 0003](docs/adr/0003-reuse-the-existing-experimental-carrier.md) を参照してください。

依存 package と AtomVM image を準備します。

```sh
cd examples/hello_atomvm_modbus_robot
mise install
mix deps.get
mix atomvm.esp32.install --version v0.7.0-beta.0
```

Drive (`drive@modbus.local`、Modbus Server Unit ID 1):

```sh
ROBOT_ROLE=drive MIX_ENV=prod mix clean
ROBOT_ROLE=drive MIX_ENV=prod mix atomvm.check
ROBOT_ROLE=drive MIX_ENV=prod mix atomvm.packbeam
ROBOT_ROLE=drive MIX_ENV=prod \
  mix atomvm.esp32.flash --port /dev/ttyACM0
```

Controller (`controller@modbus.local`、Modbus Client):

```sh
MIX_ENV=prod mix clean
MIX_ENV=prod mix atomvm.check
MIX_ENV=prod mix atomvm.packbeam
MIX_ENV=prod mix atomvm.esp32.flash --port /dev/ttyACM1
```

role は compile-time configuration です。role を切り替える前に必ず `mix clean` し、同じ environment で
check、pack、flash してください。Drive を先に起動し、`drive process registered` が表示されてから Controller を
起動すると、Controller は reference mission を自動的に実行します。成功時の最後の log は次の形式です。

```text
modbus_robot: reference mission returned {:ok, %{... x_mm: 100, y_mm: 50, heading_deg: 90 ...}}
modbus_robot: mission complete state=%{... x_mm: 100, y_mm: 50, heading_deg: 90 ...}
```

map field の表示順は AtomVM build により異なる場合があります。2026-10-18 の 2-board 検証結果と実測時間は
[Stage 1 実機検証](docs/worklog/2026-10-18-stage-1-two-board-mission.md) に記録しています。

主な build-time configuration:

| environment variable | default | 意味 |
| --- | --- | --- |
| `ROBOT_ROLE` | `controller` | `controller` または `drive` |
| `ROBOT_COMMAND_TIMEOUT_MS` | `60000` | application reply timeout |
| `ROBOT_COMMAND_RETRIES` | `1` | timeout 後の追加送信回数 |
| `ROBOT_MISSION_START_DELAY_MS` | `2000` | distribution 開始後、mission を送るまでの delay |
| `ROBOT_FIRST_REQUEST_ID` | `1` | reference mission の最初の request ID |
| `ROBOT_TRACE_APPLICATION` | `true` | application command / reply を console に出力する |
| `MODBUS_UNIT_ID` | `1` | Drive の Modbus Unit ID |
| `MODBUS_POLL_INTERVAL_MS` | `20` | Controller の FC-100 poll interval |
| `MODBUS_WAIT_FOR_PEER` | Controller で `true` | `net_kernel` 開始前に FC-100 response を待つ |
| `ATOMVM_UART_SPEED` | `9600` | RS485 UART baud rate |

UART pin、chunk、queue、trace の environment variable は既存の
[distributed Erlang example](../hello_atomvm_modbus_disterl/README.md#build-time-configuration) と同じです。

## Stage 2: 3-device standard Modbus multidrop

Stage 2 は Erlang distribution を開始せず、AVModbus の標準 Function Code 3 で holding register を読みます。
Controller だけが UART を所有して request を開始し、Drive は Unit 1、Sensors は Unit 2 として自分宛ての request だけに
応答します。

| Role | default Unit ID | identity registers `[address 0, address 1]` |
| --- | ---: | --- |
| Drive | 1 | `[1, 1]` |
| Sensors | 2 | `[2, 2]` |

各 role は compile-time configuration です。現在の接続例では USB serial を確認し、次の port へ flash します。
`ttyACM` 番号は接続順で変わるため、実際の作業では USB serial または `/dev/serial/by-id/` を優先してください。

```text
Drive:      /dev/ttyACM0  38:44:BE:A5:04:DC
Sensors:    /dev/ttyACM1  10:BD:A3:CF:09:04
Controller: /dev/ttyACM2  38:44:BE:A5:05:14
```

Drive:

```sh
MIX_ENV=prod mix clean
ROBOT_MODE=multidrop ROBOT_ROLE=drive MIX_ENV=prod mix atomvm.check
ROBOT_MODE=multidrop ROBOT_ROLE=drive MIX_ENV=prod mix atomvm.packbeam
ROBOT_MODE=multidrop ROBOT_ROLE=drive MIX_ENV=prod \
  mix atomvm.esp32.flash --port /dev/ttyACM0
```

Sensors:

```sh
MIX_ENV=prod mix clean
ROBOT_MODE=multidrop ROBOT_ROLE=sensors MIX_ENV=prod mix atomvm.check
ROBOT_MODE=multidrop ROBOT_ROLE=sensors MIX_ENV=prod mix atomvm.packbeam
ROBOT_MODE=multidrop ROBOT_ROLE=sensors MIX_ENV=prod \
  mix atomvm.esp32.flash --port /dev/ttyACM1
```

Controller:

```sh
MIX_ENV=prod mix clean
ROBOT_MODE=multidrop ROBOT_ROLE=controller MIX_ENV=prod mix atomvm.check
ROBOT_MODE=multidrop ROBOT_ROLE=controller MIX_ENV=prod mix atomvm.packbeam
ROBOT_MODE=multidrop ROBOT_ROLE=controller MIX_ENV=prod \
  mix atomvm.esp32.flash --port /dev/ttyACM2
```

2 台の Server を先に起動し、次に Controller を起動します。default 3 cycle が成功すると次の summary を出力します。

```text
modbus_robot_multidrop: cycle=1 role=drive unit=1 ... reply={:ok, [1, 1]}
modbus_robot_multidrop: cycle=1 role=sensors unit=2 ... reply={:ok, [2, 2]}
modbus_robot_multidrop: complete result={:ok, %{successes: 6, failures: 0, ...}}
```

主な Stage 2 build-time configuration:

| environment variable | default | 意味 |
| --- | --- | --- |
| `ROBOT_MODE` | `distributed` | Stage 2では`multidrop` |
| `ROBOT_ROLE` | `controller` | `controller`、`drive`、`sensors` |
| `ROBOT_DRIVE_UNIT_ID` | `1` | Controller が poll する Drive Unit ID |
| `ROBOT_SENSORS_UNIT_ID` | `2` | Controller が poll する Sensors Unit ID |
| `MODBUS_UNIT_ID` | role 依存 | Server 自身の Unit ID。Drive 1、Sensors 2 |
| `ROBOT_MULTIDROP_CYCLES` | `3` | Drive→Sensors poll を繰り返す回数 |
| `ROBOT_MULTIDROP_INTERVAL_MS` | `1000` | cycle 間隔 |
| `ROBOT_MULTIDROP_START_DELAY_MS` | `2000` | Controller が最初の request を送るまでの delay |
| `ROBOT_MULTIDROP_GAP_MS` | `20` | 各 RTU 送信前の minimum gap |
| `MODBUS_RESPONSE_TIMEOUT_MS` | `500` | 1 回の response timeout |

60 cycle / 120 request の soak と両 Server の独立 reboot 結果は
[Stage 2 実機検証](docs/worklog/2026-10-19-stage-2-multidrop.md) に記録しています。Stage 2 と Stage 3 を分離する理由は
[ADR 0004](docs/adr/0004-validate-standard-multidrop-before-distribution.md) を参照してください。

## Stage 3: 3-node distributed Erlang probe

Stage 3 は `serial_dist` の `uart_ports` に 2 個の virtual UART handle を渡します。Controller 側の各 adapter は独立した
sequence / ACK / session / byte-stream state を持ちますが、外部所有の 1 個の `AVModbus.Client` を共有します。これにより、
physical UART と active Modbus transaction は常に 1 個の Client process が所有します。Drive と Sensors は自分の stream から
Controller への distribution connection を開始します。readiness message は起動ごとの boot session ID を持つため、AtomVM が
reboot 前後で同じ PID を再利用しても remote restart を識別できます。

application relay は transport routing ではありません。Controller は `:modbus_robot_sensors` へ sample を要求し、値を検証してから
`:modbus_robot_drive` へ転送します。Drive が同じ sample を含む ACK を返した時点で完了とします。physical bus 上では両区間とも
Controller の Modbus Client が transaction を開始します。この境界の判断は
[ADR 0007](docs/adr/0007-relay-server-application-messages-through-controller.md) に記録しています。

現在の実機 baseline は `ATOMVM_UART_SPEED=115200` です。9,600 baud では 2 connection の handshake が AtomVM の固定 7 秒
setup timer に収まりませんでした。また、複数 connection の最初の tick で `net_kernel` が crash する AtomVM bug が見つかり、
local patch で修正して 90 秒間 connection を維持しました。公式 AtomVM image のまま長時間利用できるという意味ではありません。
必要な patch と build 条件は
[Stage 3 実機検証](docs/worklog/2026-10-19-stage-3-three-node-distribution.md) に記録しています。

各 role を build する基本形は次のとおりです。port は Stage 2 と同じ対応です。

```sh
# Controller
MIX_ENV=prod mix clean
ROBOT_MODE=multinode ROBOT_ROLE=controller ATOMVM_UART_SPEED=115200 \
  MIX_ENV=prod mix atomvm.check
ROBOT_MODE=multinode ROBOT_ROLE=controller ATOMVM_UART_SPEED=115200 \
  MIX_ENV=prod mix atomvm.packbeam
ROBOT_MODE=multinode ROBOT_ROLE=controller ATOMVM_UART_SPEED=115200 \
  MIX_ENV=prod mix atomvm.esp32.flash --port /dev/ttyACM2

# Drive
MIX_ENV=prod mix clean
ROBOT_MODE=multinode ROBOT_ROLE=drive ATOMVM_UART_SPEED=115200 \
  MIX_ENV=prod mix atomvm.packbeam
ROBOT_MODE=multinode ROBOT_ROLE=drive ATOMVM_UART_SPEED=115200 \
  MIX_ENV=prod mix atomvm.esp32.flash --port /dev/ttyACM0

# Sensors
MIX_ENV=prod mix clean
ROBOT_MODE=multinode ROBOT_ROLE=sensors ATOMVM_UART_SPEED=115200 \
  MIX_ENV=prod mix atomvm.packbeam
ROBOT_MODE=multinode ROBOT_ROLE=sensors ATOMVM_UART_SPEED=115200 \
  MIX_ENV=prod mix atomvm.esp32.flash --port /dev/ttyACM1
```

Controller の継続 traffic probe は opt-in です。compile-time configuration のため、値を変更する前に `mix clean` を実行します。

```sh
MIX_ENV=prod mix clean
ROBOT_MODE=multinode ROBOT_ROLE=controller ATOMVM_UART_SPEED=115200 \
  ROBOT_MULTINODE_SOAK_CYCLES=30 ROBOT_MULTINODE_SOAK_PAYLOAD_BYTES=128 \
  MIX_ENV=prod mix atomvm.packbeam
ROBOT_MODE=multinode ROBOT_ROLE=controller ATOMVM_UART_SPEED=115200 \
  ROBOT_MULTINODE_SOAK_CYCLES=30 ROBOT_MULTINODE_SOAK_PAYLOAD_BYTES=128 \
  MIX_ENV=prod mix atomvm.esp32.flash --port /dev/ttyACM2
```

| 環境変数 | 既定値 | 意味 |
| --- | ---: | --- |
| `ROBOT_MULTINODE_SOAK_CYCLES` | `0` | `0` は無効。1 cycle で両 role へ 1 回ずつ送る |
| `ROBOT_MULTINODE_SOAK_PAYLOAD_BYTES` | `128` | echo して内容を照合する application payload size |
| `ROBOT_MULTINODE_SOAK_INTERVAL_MS` | `250` | cycle 間の待ち時間 |
| `ROBOT_MULTINODE_SOAK_RETRIES` | `1` | 対象 role の reboot を検出した場合の再送回数 |
| `ROBOT_MULTINODE_ANNOUNCE_MS` | `30000` | 接続済み remote の readiness heartbeat 間隔 |
| `ROBOT_MULTINODE_HEALTH_CHECK_MS` | `5000` | Controller が role 別 lease を確認する間隔 |
| `ROBOT_MULTINODE_LEASE_MS` | `75000` | 最後の readiness から remote unavailable とするまでの期限 |
| `ROBOT_SENSOR_MISSION_STEPS` | `3` | 起動後に直列実行する sensor-driven mission の step 数 |
| `ROBOT_DRIVE_DROP_FIRST_REPLY_PER_REQUEST` | `false` | Drive が各 request の初回 reply を破棄する fault injection |

odd cycle は Drive、even cycle は Sensors を先に実行し、固定順による測定 bias を減らします。2026-10-19 の 30-cycle run は
60 round trip を 198,745 ms で完了し、両 role とも 30 / 30 成功、失敗 0 でした。Drive の平均 RTT は 3,184 ms、Sensors は
3,180 ms で、差は 4 ms でした。詳細は
[application traffic soak](docs/worklog/2026-10-19-stage-3-application-soak.md) に記録しています。

20-cycle run の進行中に Drive と Sensors を 1 回ずつ reset した試験でも、各 role は 20 / 20 成功しました。reboot をまたいだ
Drive probe は 11,847 ms、Sensors probe は 9,887 ms で、どちらも新 boot session の検出後に 1 回再送して成功しています。
この retry は echo probe が idempotent であることを前提とし、一般の robot command に exactly-once semantics を与えるものでは
ありません。詳細は [traffic 中の reboot](docs/worklog/2026-10-19-stage-3-soak-reboot.md) を参照してください。

成功時、Controller は次の log を出します。

```text
modbus_robot_multinode: connected role=drive node=:drive@modbus.local
modbus_robot_multinode: connected role=sensors node=:sensors@modbus.local
modbus_robot_multinode: both remote nodes connected
modbus_robot_multinode: probe reply role=drive node=:drive@modbus.local
modbus_robot_multinode: probe reply role=sensors node=:sensors@modbus.local
modbus_robot_multinode: sensor mission step=1 sample=%{sequence: 1, distance_mm: 500, battery_percent: 100} reason=clear_path command={:forward, 100} state=%{...}
modbus_robot_multinode: sensor mission step=2 sample=%{sequence: 2, distance_mm: 450, battery_percent: 99} reason=clear_path command={:forward, 100} state=%{...}
modbus_robot_multinode: sensor mission step=3 sample=%{sequence: 3, distance_mm: 400, battery_percent: 98} reason=obstacle command={:turn, :right, 90} state=%{...}
modbus_robot_multinode: sensor mission complete state=%{... x_mm: 200, y_mm: 0, heading_deg: 90 ...}
modbus_robot_multinode: complete Drive and Sensors remote messaging
```

remote を単独で reset すると、Controller は再接続した role と接続を維持した peer の両方へ probe を送ります。

```text
modbus_robot_multinode: reconnected role=drive node=:drive@modbus.local
modbus_robot_multinode: probe reply role=drive node=:drive@modbus.local
modbus_robot_multinode: probe reply role=sensors node=:sensors@modbus.local
modbus_robot_multinode: recovery complete restarted=drive peer=sensors
```

`ROBOT_MULTINODE_ANNOUNCE_MS` の既定値は `30000` です。これは接続済み remote が Controller へ readiness heartbeat を送る間隔で、
remote reboot の検出には起動直後の announce を使います。Controller 単独 reboot 後も、両 remote が heartbeat で再登録して
probe を完了することを実機確認しています。

この relay は 2026-10-19 に 3 台の実機で確認しました。sample、Drive の last sample、sequence は volatile であり、reboot をまたぐ
durable delivery や exactly-once semantics はありません。host test と実機条件は
[Controller-mediated sensor relay](docs/worklog/2026-10-19-stage-3-controller-relay.md) に記録しています。

shared Client と `uart_ports` を採用した理由は
[ADR 0005](docs/adr/0005-share-one-client-across-distribution-streams.md)、boot session ID の判断は
[ADR 0006](docs/adr/0006-identify-remote-boots-with-session-ids.md) を参照してください。Drive / Sensors の独立 reboot recovery は実機確認済みです。
Controller reboot recovery、application traffic の短時間 fairness baseline、Drive / Sensors 間の Controller relay も実機確認済みです。
concurrent producer の baseline と moderate profile は2026-10-20に実機確認しました。より長時間の soak、memory / queue 推移、
overload 時の公平性は未完了です。

## Stage 4: sensor-driven mission

`RobotSim.Navigator` は sample に対して pure な判断を行います。battery が 20% 以下なら `:status` で位置を保持し、それ以外で
distance が 400 mm 以下なら右へ 90° 旋回します。どちらにも該当しなければ 100 mm 前進します。low battery を obstacle より
優先します。

fresh Sensors の最初の 3 sample は 500、450、400 mm です。このため Controller は `forward, forward, right turn` を選び、fresh
Drive の final state は `(x=200, y=0, heading=90°)` になります。Controller は起動ごとの random ID から command request-ID range を
開始し、timeout retry に限って同じ ID を再利用します。判断理由は
[ADR 0008](docs/adr/0008-make-navigation-decisions-in-controller.md)、host test と3台の実機結果は
[Stage 4 adaptive mission worklog](docs/worklog/2026-10-19-stage-4-adaptive-mission.md) を参照してください。

remote PID に対する native distributed `Process.monitor/1` も試しましたが、現在の AtomVM-to-AtomVM / alternative carrier 構成では
`erlang:monitor/2` が `badarg` となりました。そのため、現在は readiness heartbeat の最終受信時刻を role ごとに保持し、75秒の
default lease を超えた role だけを unavailable とします。Drive / Sensors を個別に停止した実機試験では、稼働中 peer の lease と
connection を維持し、復帰 node と peer の両方へ probe が成功しました。設計判断は
[ADR 0009](docs/adr/0009-use-readiness-leases-for-remote-health.md)、実機結果は
[remote health worklog](docs/worklog/2026-10-19-stage-4-remote-health.md) に記録しています。lease を短くしすぎると queued heartbeat による
false positive が起きるため、`ROBOT_MULTINODE_LEASE_MS` は heartbeat interval と transport latency に十分な余裕を持たせる必要があります。

movement retry の重複排除を調べる fault injection は opt-in です。Drive で
`ROBOT_DRIVE_DROP_FIRST_REPLY_PER_REQUEST=true` を指定すると、新しい request を実行した直後の reply だけを破棄します。同じ
request ID の retry には cache 済み result を返すため、state transition は再実行しません。たとえば3-node構成では Drive を次のように
buildします。

```sh
MIX_ENV=prod mix clean
ROBOT_MODE=multinode ROBOT_ROLE=drive ATOMVM_UART_SPEED=115200 \
  ROBOT_DRIVE_DROP_FIRST_REPLY_PER_REQUEST=true \
  MIX_ENV=prod mix atomvm.packbeam
```

Controller では `ROBOT_COMMAND_RETRIES` を1以上にします。試験時間を短縮する場合も、`ROBOT_COMMAND_TIMEOUT_MS` は正常時の
application RTT より十分長くしてください。この injection は reply loss だけを再現し、Drive reboot や cache eviction 後の
重複排除は保証しません。通常の実行では必ず既定値 `false` を使用します。host test、build 条件、3台実機で4 request すべてが
same-ID retry に成功した結果は
[reply loss fault injection worklog](docs/worklog/2026-10-20-stage-4-reply-loss-fault-injection.md) に記録しています。

## 境界

buffer、application state、failure detection、recovery guarantee の詳細は
[既知の制約](docs/limitations.md) にまとめています。

- simulation logic と transport / process lifecycle を分離する
- AVModbus core を変更せず、shared carrier の修正は両 example で必要な汎用的互換性に限定する
- carrier の再利用境界を ADR 0003 に保ち、大量の source copy を避ける
- standard multidrop と 3-node distribution を別の mode・milestone として扱う
- Stage 3 は local AtomVM patch を必要とする experimental baseline として扱う
- automatic retry の前に command ID と重複実行防止を設計する
- physical actuator、real-time control、safety-critical control を対象にしない

資料の一覧と更新方針は [docs/README.md](docs/README.md) にあります。

## 次の実験: concurrent producer traffic（負荷検証中）

既存の交互順 soak は Controller が Drive と Sensors に順番に request を送る試験です。
新しい opt-in probe では、**Drive と Sensors がそれぞれ独立した process から定期的に message を送ります**。
Controller は別 process で受信状況を集計するため、通常の readiness lease loop は probe の終了を待ちません。
通信自体は従来どおり 1 個の Modbus Client が physical bus を占有します。

Controller の compile-time configuration に次の値を指定します。Drive と Sensors も新しい message handler を含む
firmware へ更新してください。各 role の build 前に `mix clean` が必要です。

```sh
# Drive と Sensors は上記 Stage 3 と同じ条件で rebuild / flash
# Controller: default の sensor mission 完了後に concurrent probe を開始
MIX_ENV=prod mix clean
ROBOT_MODE=multinode ROBOT_ROLE=controller ATOMVM_UART_SPEED=115200 \
  ROBOT_MULTINODE_TRAFFIC_SAMPLES=5 \
  ROBOT_MULTINODE_TRAFFIC_DRIVE_INTERVAL_MS=2000 \
  ROBOT_MULTINODE_TRAFFIC_SENSORS_INTERVAL_MS=1000 \
  MIX_ENV=prod mix atomvm.packbeam
# 上記と同じ environment で Controller へ flash する
```

| environment variable | default | 用途 |
| --- | ---: | --- |
| `ROBOT_MULTINODE_TRAFFIC_SAMPLES` | `0` | 0 は無効。1..64 messages / role |
| `ROBOT_MULTINODE_TRAFFIC_DRIVE_INTERVAL_MS` | `2000` | Drive producer の送信間隔 |
| `ROBOT_MULTINODE_TRAFFIC_SENSORS_INTERVAL_MS` | `1000` | Sensors producer の送信間隔 |
| `ROBOT_MULTINODE_TRAFFIC_PAYLOAD_BYTES` | `16` | 0..128 bytes の deterministic payload |
| `ROBOT_MULTINODE_TRAFFIC_TIMEOUT_MS` | `120000` | Controller collector の run 全体の timeout |
| `ROBOT_MULTINODE_TRAFFIC_SETTLE_MS` | `30000` | 完了後の settled metrics を採取するまでの待機時間。0 は無効 |
| `ROBOT_MULTINODE_TRAFFIC_ACK_TIMEOUT_MS` | `90000` | producerがapplication ACKを待つ期限 |
| `ROBOT_MULTINODE_TRAFFIC_ACK_RETRIES` | `1` | ACK timeout後に同じrun ID / sequenceを再送する回数 |

各remote producerはstarted、sample、finishedごとにControllerのapplication ACKを待ちます。roleごとのin-flight windowは1で、
producer intervalはACK受信後の最小待ち時間です。この境界は
[ADR 0010](docs/adr/0010-bound-concurrent-producers-with-application-acks.md)に記録しています。

`modbus_robot_traffic: complete` の `drive` / `sensors` summary は、それぞれ expected、received、missing、
duplicates、out_of_order、invalid、duration_ms、sample_span_ms、throughput_milli_messages_per_second、
max_interarrival_ms を示します。`fairness` は role 間の delivery ratio、completion time、最大受信間隔の差を示します。
加えて `start_skew_ms` と `active_overlap_ms` で、2 producer の受信 window が実際に重なったかを確認できます。
**max_interarrival_ms は Controller が観測した受信間隔であり、one-way latency ではありません**。
別 device の monotonic clock を比較しないためです。

2026-10-20 に3台、115,200 baud で次を確認しました。

| Profile | Result | Elapsed | Active overlap | Completion skew |
| --- | --- | ---: | ---: | ---: |
| baseline: 5 messages / role、16 bytes | 両 role 5 / 5、error 0 | 10,588 ms | 4,448 ms | 4,145 ms |
| moderate: 10 messages / role、32 bytes | 両 role 10 / 10、error 0 | 11,593 ms | 8,655 ms | 937 ms |
| overload: 20 messages / role、64 bytes | 両 role 20 / 20、Drive transaction timeout 1 | 29,769 ms | 23,579 ms | 1,310 ms |
| longer: 64 messages / role、64 bytes | Drive 23 / 64、Sensors 24 / 64、session reset後timeout | 300,001 ms | unavailable | unavailable |
| longer + ACK: 64 messages / role、64 bytes | 両 role 64 / 64、error 0 | 163,039 ms | 156,298 ms | 3,114 ms |

baseline、moderate、overload の application delivery は missing、duplicate、out-of-order、invalid がすべて0でした。longer run では
両 carrier session が再生成され、distribution reconnect 後も元の producer は再開されませんでした。短時間に各1 run の結果であり、
3台同時consoleで再試験したところ、Sensors側outgoing queueの`:queue_full`がsession resetの直接原因だと確認できました。
Controllerのmetricsはremote側queueを表さないため、長時間安定性やmemory上限を保証しません。詳細は
[concurrent traffic worklog](docs/worklog/2026-10-20-concurrent-traffic.md)と
[overload / longer run worklog](docs/worklog/2026-10-20-overload-and-long-run.md)、
[ACK flow-control worklog](docs/worklog/2026-10-20-ack-flow-control.md)を参照してください。

[実験計画と制約](docs/next-experiments.md)を参照してください。
