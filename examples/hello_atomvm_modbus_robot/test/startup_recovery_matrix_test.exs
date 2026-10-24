defmodule RobotSim.StartupRecoveryMatrixTest do
  use ExUnit.Case, async: true

  alias RobotSim.StartupRecoveryMatrix, as: Matrix

  test "6通りの起動順序と4個の障害scenarioを列挙する" do
    matrix = Matrix.matrix()

    assert length(matrix) == 10
    assert Enum.count(matrix, &(&1.category == :startup_order)) == 6
    assert Enum.count(matrix, &(&1.category == :initial_handshake_failure)) == 2
    assert Enum.count(matrix, &(&1.category == :established_connection_outage)) == 2

    assert matrix
           |> Enum.filter(&(&1.category == :startup_order))
           |> Enum.map(& &1.boot_order)
           |> Enum.sort() == Enum.sort(permutations([:controller, :drive, :sensors]))
  end

  test "起動順序scenarioは両remoteの接続証跡を要求する" do
    assert {:ok, scenario} = Matrix.fetch(:startup_controller_drive_sensors)

    assert {:remote_connected, :drive} in scenario.required
    assert {:remote_connected, :sensors} in scenario.required
    assert {:readiness_acknowledged, :drive} in scenario.required
    assert {:readiness_acknowledged, :sensors} in scenario.required
    assert scenario.boot_order == [:controller, :drive, :sensors]
  end

  test "全証跡が揃った起動順序runをpassedと判定する" do
    observations = startup_observations([:controller, :drive, :sensors])

    assert {:ok, report} =
             Matrix.evaluate(:startup_controller_drive_sensors, observations)

    assert report.outcome == :passed
    assert report.missing == []
    assert report.ordering_violations == []

    assert report.role_states == %{
             controller: :distribution_ready,
             drive: :connected,
             sensors: :connected
           }
  end

  test "指定と異なる起動順序をincompleteとして順序違反に残す" do
    observations = startup_observations([:drive, :controller, :sensors])

    assert {:ok, report} =
             Matrix.evaluate(:startup_controller_drive_sensors, observations)

    assert report.outcome == :incomplete
    assert report.missing == []
    assert length(report.ordering_violations) == 1
  end

  test "初回handshake failureだけを観測したrunをruntime blockerと判定する" do
    observations = [
      observation(:role_started, :drive, 0),
      observation(:distribution_start_started, :drive, 1),
      observation(:initial_connection_timeout, :drive, 8_001, wait_ms: 8_000),
      observation(:role_started, :controller, 8_000),
      observation(:role_started, :sensors, 9_000)
    ]

    assert {:ok, report} = Matrix.evaluate(:initial_handshake_timeout_drive, observations)
    assert report.outcome == :runtime_blocker
    assert report.blocker == {:initial_connection_timeout, :drive}
    refute report.fault_role_restarted
    assert report.role_states.drive == :awaiting_recovery
  end

  test "初回failure後のbounded restartで接続したrunをrecovered_after_failureとする" do
    failure = [
      observation(:role_started, :drive, 0),
      observation(:distribution_start_started, :drive, 1),
      observation(:initial_connection_timeout, :drive, 8_001, wait_ms: 8_000),
      observation(:restart_started, :drive, 8_002),
      observation(:restart_succeeded, :drive, 8_100),
      observation(:restart_budget_exhausted, :drive, 16_100)
    ]

    recovered =
      failure ++
        ([:drive, :controller, :sensors]
         |> startup_observations(9_000)
         |> Enum.reject(&(&1.event == :role_started and &1.role == :drive)))

    assert {:ok, report} = Matrix.evaluate(:initial_handshake_timeout_drive, recovered)
    assert report.outcome == :recovered_after_failure
    assert report.missing == []
    assert report.blocker == {:initial_connection_timeout, :drive}
    refute report.fault_role_restarted
    assert report.role_states.drive == :connected
  end

  test "board resetだけで復旧したrunをautomatic recoveryとしない" do
    failure = [
      observation(:role_started, :drive, 0),
      observation(:initial_connection_timeout, :drive, 8_001, wait_ms: 8_000)
    ]

    recovered_after_board_reset = startup_observations([:drive, :controller, :sensors], 9_000)

    assert {:ok, report} =
             Matrix.evaluate(
               :initial_handshake_timeout_drive,
               failure ++ recovered_after_board_reset
             )

    assert report.outcome == :runtime_blocker
    assert {:restart_started, :drive} in report.missing
    assert {:restart_succeeded, :drive} in report.missing
    assert report.fault_role_restarted
  end

  test "接続後障害は対象peerの復旧と正常peerの維持を別々に要求する" do
    observations =
      startup_observations([:drive, :sensors, :controller]) ++
        [
          observation(:stale_detected, :sensors, 90_000),
          observation(:restart_started, :sensors, 90_010),
          observation(:restart_succeeded, :sensors, 90_100),
          observation(:remote_reconnected, :sensors, 95_000),
          observation(:recovery_verified, :sensors, 95_100),
          observation(:peer_maintained, :drive, 95_101)
        ]

    assert {:ok, report} = Matrix.evaluate(:established_outage_sensors, observations)
    assert report.outcome == :passed
    assert report.role_states.drive == :connected
    assert report.role_states.sensors == :connected
  end

  test "復旧対象だけ再接続してもpeer維持証跡がなければincompleteとする" do
    observations =
      startup_observations([:drive, :sensors, :controller]) ++
        [
          observation(:stale_detected, :drive, 90_000),
          observation(:restart_started, :drive, 90_010),
          observation(:restart_succeeded, :drive, 90_100),
          observation(:remote_reconnected, :drive, 95_000),
          observation(:recovery_verified, :drive, 95_100)
        ]

    assert {:ok, report} = Matrix.evaluate(:established_outage_drive, observations)
    assert report.outcome == :incomplete
    assert report.missing == [{:peer_maintained, :sensors}]
  end

  test "restart failureをruntime blockerとして分類する" do
    observations =
      startup_observations([:drive, :sensors, :controller]) ++
        [
          observation(:stale_detected, :sensors, 90_000),
          observation(:restart_started, :sensors, 90_010),
          observation(:restart_failed, :sensors, 92_000, reason: :net_kernel_stop_timeout)
        ]

    assert {:ok, report} = Matrix.evaluate(:established_outage_sensors, observations)
    assert report.outcome == :runtime_blocker
    assert report.blocker == {:restart_failed, :sensors}
    assert report.role_states.sensors == :restart_failed
  end

  test "未知scenarioと不正eventを拒否する" do
    assert Matrix.evaluate(:unknown, []) == {:error, :unknown_scenario}

    assert Matrix.evaluate(:startup_controller_drive_sensors, [
             %{event: :unknown, role: :controller, at_ms: 0}
           ]) == {:error, {:invalid_event, :unknown}}
  end

  test "混在logからtraceだけを抽出して評価する" do
    lines =
      [:controller, :drive, :sensors]
      |> startup_observations()
      |> Enum.map(fn observation ->
        RobotSim.ConnectionTrace.format(observation.event, observation.at_ms,
          role: observation.role
        )
      end)

    lines = ["unrelated startup log" | lines]

    assert {:ok, report} =
             Matrix.evaluate_lines(:startup_controller_drive_sensors, lines)

    assert report.outcome == :passed
    assert report.observation_count == 15
  end

  defp startup_observations(order, start_at \\ 0) do
    boot_events =
      order
      |> Enum.with_index()
      |> Enum.map(fn {role, index} -> observation(:role_started, role, start_at + index) end)

    boot_events ++
      [
        observation(:carrier_peer_ready, :drive, start_at + 10),
        observation(:carrier_peer_ready, :sensors, start_at + 11),
        observation(:distribution_start_started, :controller, start_at + 12),
        observation(:distribution_start_succeeded, :controller, start_at + 20),
        observation(:distribution_start_succeeded, :drive, start_at + 21),
        observation(:readiness_wait_started, :drive, start_at + 22),
        observation(:remote_connected, :drive, start_at + 23),
        observation(:readiness_acknowledged, :drive, start_at + 24),
        observation(:distribution_start_succeeded, :sensors, start_at + 25),
        observation(:readiness_wait_started, :sensors, start_at + 26),
        observation(:remote_connected, :sensors, start_at + 27),
        observation(:readiness_acknowledged, :sensors, start_at + 28)
      ]
  end

  defp observation(event, role, at_ms, metadata \\ []) do
    Matrix.observation(event, role, at_ms, Map.new(metadata))
  end

  defp permutations([]), do: [[]]

  defp permutations(items) do
    for item <- items,
        rest <- permutations(List.delete(items, item)),
        do: [item | rest]
  end
end
