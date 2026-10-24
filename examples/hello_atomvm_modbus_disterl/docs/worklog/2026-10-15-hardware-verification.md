# XIAO ESP32-C5 2台での実機検証 — 2026-10-15

## 環境

- ホスト: Linux（Debian / LMDE）、timezone Asia/Tokyo
- Board A / Client: XIAO ESP32-C5、`/dev/ttyACM1`、USB serial `38:44:BE:A5:05:14`
- Board B / Server: XIAO ESP32-C5、`/dev/ttyACM0`、USB serial `38:44:BE:A5:04:DC`
- AtomVM: `v0.7.0-beta.0+git.8d3e051` (`v0.7.0-beta.0-dirty` build info)
- ESP-IDF: `v5.5.5`
- HW-519 × 2、2線式RS485、9,600 baud、8N1
- UART1: TX GPIO23、RX GPIO24
- Modbus Unit ID 1、custom Function Code 100

`mix atomvm.esp32.info`で両deviceがESP32-C5として認識され、AtomVMがinstall済みであることを確認した。

## Phase 1の結果

Serverはrequestを受信する前に3 messageをqueueした。Clientも独立して3 messageをqueueし、すべての物理transactionを開始した。

Server:

```text
disterl_probe: mode=transport role=server unit=1 function=100
disterl_probe: server ready; 3 replies queued independently
disterl_probe: server received "client message 1"
disterl_probe: server received "client message 2"
disterl_probe: server received "client message 3"
```

Client:

```text
disterl_probe: mode=transport role=client unit=1 function=100
disterl_probe: client started; 3 messages queued
disterl_probe: client received "server message 1"
disterl_probe: client received "server message 2"
disterl_probe: client received "server message 3"
disterl_probe: complete (3 ordered messages each way; all acknowledged)
```

順序保証と重複抑止はホストテストでも確認した。応答消失は、変更していないsender stateへ次のpacketを要求することで再現した。
再生成されたsequenceとpayloadは同一で、receiverはそのsequenceを1回だけ配送した。

## Timeoutと復旧

Serverを`MODBUS_START_DELAY_MS=60000`でbuildし、ServerがUART1をopenする前にClientをresetした。
Clientは4回timeoutした間も送信中のsequenceを保持し、Serverが利用可能になると手動操作なしで完了した。

```text
disterl_probe: client started; 3 messages queued
disterl_probe: exchange failed :timeout; retrying
disterl_probe: exchange failed :timeout; retrying
disterl_probe: exchange failed :timeout; retrying
disterl_probe: exchange failed :timeout; retrying
disterl_probe: client received "server message 1"
disterl_probe: client received "server message 2"
disterl_probe: client received "server message 3"
disterl_probe: complete (3 ordered messages each way; all acknowledged)
```

その後、ServerはClientからの3 messageを順番どおりに記録した。

## Phase 2の結果

`DisterlProbe.ModbusUART`をAtomVM `serial_dist`の`uart_module`として指定した。AtomVMと
AVModbus coreのsourceは変更していない。Clientのpoll intervalは20 ms、Modbus response timeoutは500 msとした。
測定前に両boardを同時にresetした。

Client (`a@modbus.local`):

```text
modbus_disterl: sending ping 1 to :b@modbus.local
modbus_uart: queued bytes=32
modbus_uart: queued bytes=37
modbus_uart: delivered bytes=11
modbus_uart: delivered bytes=41
modbus_uart: queued bytes=29
modbus_uart: delivered bytes=25
modbus_uart: queued bytes=107
modbus_uart: delivered bytes=101
modbus_disterl: received pong 1 from :b@modbus.local rtt_ms=2671
modbus_disterl: first remote reply connection_ms=12840
modbus_disterl: sending ping 2 to :b@modbus.local
modbus_disterl: received pong 2 from :b@modbus.local rtt_ms=802
modbus_disterl: sending ping 3 to :b@modbus.local
modbus_disterl: received pong 3 from :b@modbus.local rtt_ms=802
modbus_disterl: complete 3 remote ping/pong messages
```

Server (`b@modbus.local`):

```text
modbus_uart: delivered bytes=32
modbus_uart: delivered bytes=37
modbus_uart: queued bytes=11
modbus_uart: queued bytes=41
modbus_uart: delivered bytes=29
modbus_uart: queued bytes=25
modbus_uart: delivered bytes=107
modbus_disterl: received ping 1 from :a@modbus.local
modbus_uart: queued bytes=101
modbus_disterl: received ping 2 from :a@modbus.local
modbus_uart: queued bytes=101
modbus_disterl: received ping 3 from :a@modbus.local
modbus_uart: queued bytes=101
```

両monitorを接続できるよう、最初のpingはboot後に意図的に10秒遅延させた。このため`connection_ms=12840`には
10秒のdelayが含まれる。最初のRTTにはdistribution handshakeが含まれ、以降の802 msはこの構成で観測した
steady-stateのremote message round tripを示す。

message完了後も、残り45秒の観測中に両側は10-byteの`serial_dist` tick frameを交換し続け、crashやUART errorは発生しなかった。

## 統合で得られた知見

- virtual UART方式は適している。`serial_dist`はcustom `uart_module`を指定できる。
- adapterは`read(handle)`と`read(handle, :infinity)`の両方を実装する必要がある。後者は`dist_util`のhandshake受信で使われる。
- timeoutしたhandshakeにより、終了するcontrollerが所有するvirtual readがblockされたまま残る場合がある。
  adapterはlink managerが次のreadを開始するときに、この古いreaderを置き換える。
- このproof of conceptに専用`modbus_dist` carrierは不要である。
- FC-100 headerにboot/session IDがないため、この時点では片側boardの再起動は堅牢ではなかった。
  両endpointをresetするまで`:invalid_acknowledgment`が続く症状を観測した。今後のcarrierにはsession negotiationと
  明示的な再同期が必要である。
- AtomVM固定の7秒distribution setup timerとModbusのrequest/response latencyが主な時間制約となる。
  検証した20 ms poll intervalでは時間内にhandshakeが完了した。
- PackBEAMは生成されたElixir `GenServer`のerror-reporting code内に`erlang:phash2/2`を検出した。
  検証した正常系はこのunsupported codeへ入らない。追試では生成されたfallback callbackを置き換えてwarningを除去した。次を参照する。
  [PackBEAM `phash2/2` warningの除去](2026-10-16-packbeam-phash2.md)を参照する。

ここで記録したsessionと片側再起動の制約は追試で解消した。
[sessionを考慮した再起動復旧 — 2026-10-16](2026-10-16-session-recovery.md)を参照する。
