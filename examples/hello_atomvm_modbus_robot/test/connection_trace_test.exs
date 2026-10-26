defmodule RobotSim.ConnectionTraceTest do
  use ExUnit.Case, async: true

  import ExUnit.CaptureIO

  alias RobotSim.ConnectionTrace
  alias RobotSim.StartupRecoveryMatrix, as: Matrix

  test "field順を維持してconnection eventを整形する" do
    assert ConnectionTrace.format(
             :remote_reconnected,
             12_345,
             role: :sensors,
             boot_id: 100,
             connection_id: 200
           ) ==
             "modbus_robot_connection: at_ms=12345 event=remote_reconnected " <>
               "role=sensors boot_id=100 connection_id=200"
  end

  test "無効時はlogを出力しない" do
    assert capture_io(fn ->
             assert :ok =
                      ConnectionTrace.emit(false, :role_started, 0, role: :controller)
           end) == ""
  end

  test "有効時は1 eventを1行で出力する" do
    assert capture_io(fn ->
             assert :ok =
                      ConnectionTrace.emit(true, :restart_failed, 99,
                        role: :drive,
                        reason: {:error, :timeout}
                      )
           end) ==
             "modbus_robot_connection: at_ms=99 event=restart_failed " <>
               "role=drive reason={:error, :timeout}\n"
  end

  test "未知のeventと不正なfieldを拒否する" do
    assert_raise ArgumentError, fn -> ConnectionTrace.format(:unknown, 0) end

    assert_raise ArgumentError, fn ->
      ConnectionTrace.format(:role_started, 0, [:invalid])
    end
  end

  test "kernel restartの各境界を個別eventとして公開する" do
    assert Enum.all?(
             [
               :kernel_stop_requested,
               :kernel_stop_completed,
               :kernel_stop_failed,
               :kernel_start_started,
               :kernel_start_succeeded,
               :kernel_start_failed
             ],
             &(&1 in ConnectionTrace.events())
           )

    assert ConnectionTrace.format(:kernel_start_succeeded, 123,
             role: :sensors,
             free_heap_bytes: 80_000,
             largest_free_block_bytes: 60_000,
             minimum_free_heap_bytes: 70_000
           ) ==
             "modbus_robot_connection: at_ms=123 event=kernel_start_succeeded " <>
               "role=sensors free_heap_bytes=80000 largest_free_block_bytes=60000 " <>
               "minimum_free_heap_bytes=70000"
  end

  test "transport復帰待ちの各境界を個別eventとして公開する" do
    assert Enum.all?(
             [:restart_deferred, :transport_resumed, :transport_ready],
             &(&1 in ConnectionTrace.events())
           )
  end

  test "他のconsole logを無視してconnection traceをparseする" do
    assert Matrix.parse_line("ordinary log") == :ignore

    assert Matrix.parse_line(
             "modbus_robot_connection: at_ms=-42 event=remote_connected " <>
               "role=drive boot_id=1 connection_id=2\n"
           ) == {:ok, %{at_ms: -42, event: :remote_connected, role: :drive}}
  end

  test "未知のeventとroleをparse時に拒否する" do
    assert Matrix.parse_line("modbus_robot_connection: at_ms=0 event=unknown role=drive") ==
             {:error, {:unknown_value, "unknown"}}

    assert Matrix.parse_line("modbus_robot_connection: at_ms=0 event=role_started role=other") ==
             {:error, {:unknown_value, "other"}}
  end
end
