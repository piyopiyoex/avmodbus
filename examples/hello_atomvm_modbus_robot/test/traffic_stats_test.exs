defmodule RobotSim.TrafficStatsTest do
  use ExUnit.Case, async: true

  alias RobotSim.TrafficStats

  test "counts missing, duplicate and out-of-order samples without relying on remote clocks" do
    stats =
      TrafficStats.new(4)
      |> TrafficStats.started(900)
      |> TrafficStats.record(1, true, 1_000)
      |> TrafficStats.record(3, true, 1_120)
      |> TrafficStats.record(3, true, 1_130)
      |> TrafficStats.record(2, true, 1_150)
      |> TrafficStats.finished(1_200)

    assert TrafficStats.summary(stats) == %{
             expected: 4,
             received: 3,
             missing: 1,
             duplicates: 1,
             out_of_order: 2,
             invalid: 0,
             started: true,
             finished: true,
             duration_ms: 300,
             sample_span_ms: 150,
             throughput_milli_messages_per_second: 10_000,
             max_interarrival_ms: 120
           }
  end

  test "invalid samples do not count as delivered" do
    stats =
      TrafficStats.new(2)
      |> TrafficStats.record(1, false, 20)
      |> TrafficStats.record(3, true, 30)
      |> TrafficStats.record(1, true, 40)

    assert TrafficStats.summary(stats).received == 1
    assert TrafficStats.summary(stats).missing == 1
    assert TrafficStats.summary(stats).invalid == 2
  end

  test "compares delivery fairness and Controller-clock completion skew" do
    drive =
      TrafficStats.new(4)
      |> TrafficStats.started(100)
      |> TrafficStats.record(1, true, 120)
      |> TrafficStats.record(2, true, 220)
      |> TrafficStats.finished(300)

    sensors =
      TrafficStats.new(4)
      |> TrafficStats.started(110)
      |> TrafficStats.record(1, true, 130)
      |> TrafficStats.record(2, true, 180)
      |> TrafficStats.record(3, true, 230)
      |> TrafficStats.record(4, true, 280)
      |> TrafficStats.finished(320)

    assert TrafficStats.fairness(drive, sensors) == %{
             delivery_ratio_gap_per_mille: 500,
             start_skew_ms: 10,
             completion_skew_ms: 20,
             active_overlap_ms: 190,
             max_interarrival_gap_ms: 50
           }
  end

  test "reports zero overlap for producer windows that never run together" do
    drive =
      TrafficStats.new(1)
      |> TrafficStats.started(100)
      |> TrafficStats.finished(200)

    sensors =
      TrafficStats.new(1)
      |> TrafficStats.started(250)
      |> TrafficStats.finished(300)

    assert TrafficStats.fairness(drive, sensors).active_overlap_ms == 0
  end
end
