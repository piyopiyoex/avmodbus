Code.require_file("../host/endurance_report.ex", __DIR__)

defmodule RobotSim.EnduranceReportTest do
  use ExUnit.Case, async: true

  alias RobotSim.EnduranceReport

  test "3 roleのresource、traffic、restartを集計する" do
    controller = """
    ordinary console line
    modbus_robot_endurance: starting run=1/2
    modbus_robot_resource: phase=periodic peer=drive queued_bytes=10 outstanding=1 max_queued_bytes=200 max_outstanding=3 free_heap_bytes=70000 minimum_free_heap_bytes=65000 global_queued_bytes=20 global_queued_chunks=2 global_max_queued_bytes=900 global_max_queued_chunks=14 global_rejected=0 transaction_failures=1
    modbus_robot_resource: phase=before peer=drive queued_bytes=0 outstanding=0 max_queued_bytes=0 max_outstanding=0 free_heap_bytes=70000 minimum_free_heap_bytes=65000 global_queued_bytes=0 global_queued_chunks=0 global_max_queued_bytes=900 global_max_queued_chunks=14 global_rejected=0 transaction_failures=0
    modbus_robot_resource: phase=after peer=drive queued_bytes=0 outstanding=0 max_queued_bytes=200 max_outstanding=3 free_heap_bytes=69000 minimum_free_heap_bytes=64000 global_queued_bytes=0 global_queued_chunks=0 global_max_queued_bytes=920 global_max_queued_chunks=15 global_rejected=0 transaction_failures=2
    modbus_robot_resource: phase=periodic peer=sensors queued_bytes=12 outstanding=1 max_queued_bytes=210 max_outstanding=4 free_heap_bytes=69000 minimum_free_heap_bytes=64000 global_queued_bytes=22 global_queued_chunks=2 global_max_queued_bytes=920 global_max_queued_chunks=15 global_rejected=1 transaction_failures=0
    modbus_robot_multinode: concurrent traffic report run=100 outcome=complete
    modbus_robot_connection: at_ms=1 event=restart_started role=sensors
    modbus_robot_connection: at_ms=2 event=restart_succeeded role=sensors
    modbus_robot_connection: at_ms=3 event=remote_reconnected role=sensors
    modbus_robot_connection: at_ms=4 event=recovery_verified role=sensors
    modbus_robot_connection: at_ms=5 event=peer_maintained role=drive
    modbus_robot_endurance: run=1/2 outcome=complete idle_ms=1000
    modbus_robot_endurance: starting run=2/2
    modbus_robot_multinode: concurrent traffic report run=101 outcome=complete
    modbus_robot_endurance: run=2/2 outcome=complete idle_ms=0
    modbus_robot_endurance: complete run=2/2 summary=%{complete: 2}
    """

    drive =
      "modbus_robot_memory: role=drive free_heap_bytes=80000 " <>
        "largest_free_block_bytes=60000 minimum_free_heap_bytes=76000\n"

    sensors =
      "modbus_robot_memory: role=sensors free_heap_bytes=82000 " <>
        "largest_free_block_bytes=61000 minimum_free_heap_bytes=78000\n"

    assert {:ok, report} =
             EnduranceReport.analyze(%{
               controller: controller,
               drive: drive,
               sensors: sensors
             })

    assert report.successful
    assert report.traffic == %{complete: 2, timeout: 0, other: 0}

    assert report.endurance == %{
             planned_runs: 2,
             started_runs: 2,
             completed_runs: 2,
             finished: true
           }

    assert report.controller.minimum_free_heap_bytes == 64_000
    assert report.controller.max_global_queued_bytes == 920
    assert report.controller.max_global_queued_chunks == 15
    assert report.controller.global_rejected == 1
    assert report.controller.peers.drive.transaction_failures == 3
    assert report.remotes.drive.minimum_free_heap_bytes == 76_000
    assert report.remotes.sensors.minimum_observed_free_heap_bytes == 82_000
    assert report.connections["restart_started"] == 1
    assert report.connections["restart_succeeded"] == 1
    assert report.connections["remote_reconnected"] == 1
    assert report.connections["recovery_verified"] == 1
    assert report.connections["peer_maintained"] == 1
    assert report.malformed_lines == 0
  end

  test "traffic完了後のrestart失敗を成功扱いにしない" do
    logs = complete_logs("restart_started\nrestart_failed")

    assert {:ok, report} = EnduranceReport.analyze(logs)
    refute report.successful
    assert report.connections["restart_started"] == 1
    assert report.connections["restart_failed"] == 1
  end

  test "途中終了した試験でもoutcomeを得たrun数を集計する" do
    logs = %{
      controller: """
      modbus_robot_endurance: starting run=1/3
      modbus_robot_endurance: run=1/3 outcome=timeout idle_ms=0
      modbus_robot_endurance: starting run=2/3
      modbus_robot_endurance: run=2/3 outcome=complete idle_ms=0
      modbus_robot_endurance: starting run=3/3
      """
    }

    assert {:ok, report} = EnduranceReport.analyze(logs)
    assert report.endurance.completed_runs == 2
    refute report.endurance.finished
  end

  test "完了していないrestartを成功扱いにしない" do
    logs = complete_logs("restart_started")

    assert {:ok, report} = EnduranceReport.analyze(logs)
    refute report.successful
  end

  test "restart budget枯渇を成功扱いにしない" do
    logs = complete_logs("restart_budget_exhausted")

    assert {:ok, report} = EnduranceReport.analyze(logs)
    refute report.successful
    assert report.connections["restart_budget_exhausted"] == 1
  end

  test "timeoutと壊れたresource行を失敗として報告する" do
    logs = %{
      controller: """
      modbus_robot_resource: phase=periodic peer=drive queued_bytes=broken
      modbus_robot_multinode: concurrent traffic report run=1 outcome=timeout
      """
    }

    assert {:ok, report} = EnduranceReport.analyze(logs)
    refute report.successful
    assert report.traffic.timeout == 1
    assert report.malformed_lines == 1
  end

  test "map以外の入力を拒否する" do
    assert EnduranceReport.analyze("log") == {:error, :invalid_logs}
  end

  test "指定時間外の別campaignを集計しない" do
    logs = %{
      controller: """
      [09:31:00.000] modbus_robot_endurance: starting run=2/12
      [09:31:01.000] modbus_robot_multinode: concurrent traffic report run=1 outcome=timeout
      [09:32:23.000] modbus_robot_endurance: starting run=1/1
      [09:32:24.000] modbus_robot_resource: phase=after peer=drive queued_bytes=0 outstanding=0 max_queued_bytes=1 max_outstanding=1 free_heap_bytes=70000 minimum_free_heap_bytes=65000 global_queued_bytes=0 global_queued_chunks=0 global_max_queued_bytes=1 global_max_queued_chunks=1 global_rejected=0 transaction_failures=0
      [09:32:25.000] modbus_robot_resource: phase=after peer=sensors queued_bytes=0 outstanding=0 max_queued_bytes=1 max_outstanding=1 free_heap_bytes=70000 minimum_free_heap_bytes=65000 global_queued_bytes=0 global_queued_chunks=0 global_max_queued_bytes=1 global_max_queued_chunks=1 global_rejected=0 transaction_failures=0
      [09:32:26.000] modbus_robot_multinode: concurrent traffic report run=2 outcome=complete
      [09:32:27.000] modbus_robot_endurance: complete run=1/1 summary=%{complete: 1}
      [09:33:00.000] modbus_robot_multinode: concurrent traffic report run=3 outcome=timeout
      """,
      drive:
        "[09:32:23.000] modbus_robot_memory: role=drive free_heap_bytes=80000 largest_free_block_bytes=60000 minimum_free_heap_bytes=76000\n",
      sensors:
        "[09:32:23.000] modbus_robot_memory: role=sensors free_heap_bytes=82000 largest_free_block_bytes=61000 minimum_free_heap_bytes=78000\n"
    }

    assert {:ok, report} =
             EnduranceReport.analyze(logs,
               since: "09:32:23.000",
               until: "09:32:27.000"
             )

    assert report.successful
    assert report.traffic == %{complete: 1, timeout: 0, other: 0}
    assert report.endurance.started_runs == 1
  end

  test "不正な集計開始時刻を拒否する" do
    assert EnduranceReport.analyze(%{}, since: "09:32") == {:error, :invalid_timestamp}
    assert EnduranceReport.analyze(%{}, since: "25:00:00.000") == {:error, :invalid_timestamp}
  end

  test "終了時刻が開始時刻より前の範囲を拒否する" do
    assert EnduranceReport.analyze(%{}, since: "09:32:23.000", until: "09:32:22.999") ==
             {:error, :invalid_time_window}
  end

  test "trafficが完了してもremote metricsがなければ成功にしない" do
    logs = %{
      controller: """
      modbus_robot_resource: phase=after peer=drive queued_bytes=0 outstanding=0 max_queued_bytes=1 max_outstanding=1 free_heap_bytes=70000 minimum_free_heap_bytes=65000 global_queued_bytes=0 global_queued_chunks=0 global_max_queued_bytes=1 global_max_queued_chunks=1 global_rejected=0 transaction_failures=0
      modbus_robot_multinode: concurrent traffic report run=1 outcome=complete
      """
    }

    assert {:ok, report} = EnduranceReport.analyze(logs)
    refute report.successful
  end

  defp complete_logs(connection_events) do
    connection_lines =
      connection_events
      |> String.split("\n", trim: true)
      |> Enum.map_join("\n", fn event ->
        "modbus_robot_connection: at_ms=1 event=#{event} role=sensors"
      end)

    %{
      controller: """
      modbus_robot_resource: phase=after peer=drive queued_bytes=0 outstanding=0 max_queued_bytes=1 max_outstanding=1 free_heap_bytes=70000 minimum_free_heap_bytes=65000 global_queued_bytes=0 global_queued_chunks=0 global_max_queued_bytes=1 global_max_queued_chunks=1 global_rejected=0 transaction_failures=0
      modbus_robot_resource: phase=after peer=sensors queued_bytes=0 outstanding=0 max_queued_bytes=1 max_outstanding=1 free_heap_bytes=70000 minimum_free_heap_bytes=65000 global_queued_bytes=0 global_queued_chunks=0 global_max_queued_bytes=1 global_max_queued_chunks=1 global_rejected=0 transaction_failures=0
      modbus_robot_multinode: concurrent traffic report run=1 outcome=complete
      #{connection_lines}
      """,
      drive:
        "modbus_robot_memory: role=drive free_heap_bytes=80000 largest_free_block_bytes=60000 minimum_free_heap_bytes=76000\n",
      sensors:
        "modbus_robot_memory: role=sensors free_heap_bytes=82000 largest_free_block_bytes=61000 minimum_free_heap_bytes=78000\n"
    }
  end
end
