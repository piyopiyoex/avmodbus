defmodule RobotSim.MultinodeStats do
  @moduledoc false

  @type t :: %{
          successes: non_neg_integer(),
          failures: non_neg_integer(),
          total_rtt_ms: non_neg_integer(),
          min_rtt_ms: non_neg_integer() | nil,
          max_rtt_ms: non_neg_integer()
        }

  @spec new() :: t()
  def new do
    %{successes: 0, failures: 0, total_rtt_ms: 0, min_rtt_ms: nil, max_rtt_ms: 0}
  end

  @spec record_success(t(), non_neg_integer()) :: t()
  def record_success(stats, rtt_ms) when is_integer(rtt_ms) and rtt_ms >= 0 do
    %{
      stats
      | successes: stats.successes + 1,
        total_rtt_ms: stats.total_rtt_ms + rtt_ms,
        min_rtt_ms: min_rtt(stats.min_rtt_ms, rtt_ms),
        max_rtt_ms: max(stats.max_rtt_ms, rtt_ms)
    }
  end

  @spec record_failure(t()) :: t()
  def record_failure(stats), do: %{stats | failures: stats.failures + 1}

  @spec summary(t()) :: map()
  def summary(%{successes: 0} = stats) do
    %{
      successes: 0,
      failures: stats.failures,
      min_rtt_ms: nil,
      average_rtt_ms: nil,
      max_rtt_ms: nil
    }
  end

  def summary(stats) do
    %{
      successes: stats.successes,
      failures: stats.failures,
      min_rtt_ms: stats.min_rtt_ms,
      average_rtt_ms: div(stats.total_rtt_ms, stats.successes),
      max_rtt_ms: stats.max_rtt_ms
    }
  end

  @spec fairness(t(), t()) :: map()
  def fairness(drive, sensors) do
    drive_summary = summary(drive)
    sensors_summary = summary(sensors)

    %{
      drive: drive_summary,
      sensors: sensors_summary,
      success_delta: abs(drive_summary.successes - sensors_summary.successes),
      failure_delta: abs(drive_summary.failures - sensors_summary.failures),
      average_rtt_delta_ms:
        average_delta(drive_summary.average_rtt_ms, sensors_summary.average_rtt_ms)
    }
  end

  defp min_rtt(nil, rtt_ms), do: rtt_ms
  defp min_rtt(min_rtt_ms, rtt_ms), do: min(min_rtt_ms, rtt_ms)

  defp average_delta(nil, _average), do: nil
  defp average_delta(_average, nil), do: nil
  defp average_delta(left, right), do: abs(left - right)
end
