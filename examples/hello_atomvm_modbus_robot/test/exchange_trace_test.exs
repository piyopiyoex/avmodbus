defmodule RobotSim.ExchangeTraceTest do
  use ExUnit.Case, async: true

  import ExUnit.CaptureIO

  alias RobotSim.ExchangeTrace

  test "request受理eventをfield順どおり整形する" do
    assert ExchangeTrace.format(
             :request_accepted,
             12_345,
             role: :sensors,
             unit_id: 2,
             exchange_id: 10,
             peer_session: 20,
             request_payload_bytes: 96
           ) ==
             "modbus_robot_exchange: at_ms=12345 event=request_accepted " <>
               "role=sensors unit_id=2 exchange_id=10 peer_session=20 " <>
               "request_payload_bytes=96"
  end

  test "無効時はlogを出力しない" do
    assert capture_io(fn ->
             assert :ok =
                      ExchangeTrace.emit(false, :response_dropped, 0,
                        role: :sensors,
                        exchange_id: 1
                      )
           end) == ""
  end

  test "response outcomeを1行で出力する" do
    assert capture_io(fn ->
             assert :ok =
                      ExchangeTrace.emit(true, :response_returned, 99,
                        role: :drive,
                        unit_id: 1,
                        exchange_id: 2,
                        response_payload_bytes: 18
                      )
           end) ==
             "modbus_robot_exchange: at_ms=99 event=response_returned " <>
               "role=drive unit_id=1 exchange_id=2 response_payload_bytes=18\n"
  end

  test "未知のeventと不正なfieldを拒否する" do
    assert_raise ArgumentError, fn -> ExchangeTrace.format(:unknown, 0) end

    assert_raise ArgumentError, fn ->
      ExchangeTrace.format(:request_accepted, 0, [:invalid])
    end
  end
end
