defmodule RobotSim.MultinodeStatsTest do
  use ExUnit.Case, async: true

  alias RobotSim.MultinodeStats

  test "summarizes successful RTTs and failures" do
    stats =
      MultinodeStats.new()
      |> MultinodeStats.record_success(100)
      |> MultinodeStats.record_success(300)
      |> MultinodeStats.record_failure()

    assert MultinodeStats.summary(stats) == %{
             successes: 2,
             failures: 1,
             min_rtt_ms: 100,
             average_rtt_ms: 200,
             max_rtt_ms: 300
           }
  end

  test "summarizes a role with no successful replies" do
    stats = MultinodeStats.new() |> MultinodeStats.record_failure()

    assert MultinodeStats.summary(stats) == %{
             successes: 0,
             failures: 1,
             min_rtt_ms: nil,
             average_rtt_ms: nil,
             max_rtt_ms: nil
           }
  end

  test "compares per-role success counts and average RTTs" do
    drive = MultinodeStats.new() |> MultinodeStats.record_success(100)

    sensors =
      MultinodeStats.new()
      |> MultinodeStats.record_success(200)
      |> MultinodeStats.record_failure()

    assert MultinodeStats.fairness(drive, sensors) == %{
             drive: MultinodeStats.summary(drive),
             sensors: MultinodeStats.summary(sensors),
             success_delta: 0,
             failure_delta: 1,
             average_rtt_delta_ms: 100
           }
  end
end
