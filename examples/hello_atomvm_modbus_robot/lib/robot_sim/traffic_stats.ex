defmodule RobotSim.TrafficStats do
  @moduledoc """
  Bounded, Controller-clock statistics for one independent traffic producer.

  This deliberately measures delivery and interarrival gaps, not one-way
  latency: ESP32 nodes do not share a synchronized monotonic clock.
  """

  @doc "Create counters for a producer expected to send `count` samples."
  def new(count) when is_integer(count) and count > 0 do
    %{
      expected: count,
      seen: %{},
      last_sequence: 0,
      first_arrival_ms: nil,
      last_arrival_ms: nil,
      max_interarrival_ms: 0,
      duplicates: 0,
      out_of_order: 0,
      invalid: 0,
      started: false,
      started_at_ms: nil,
      finished: false,
      finished_at_ms: nil
    }
  end

  def started(stats, arrival_ms) when is_integer(arrival_ms),
    do: %{stats | started: true, started_at_ms: stats.started_at_ms || arrival_ms}

  def finished(stats, arrival_ms) when is_integer(arrival_ms),
    do: %{stats | finished: true, finished_at_ms: stats.finished_at_ms || arrival_ms}

  @doc "Record one received sample using the Controller's local monotonic time."
  def record(stats, sequence, valid_payload?, arrival_ms) when is_integer(arrival_ms) do
    cond do
      not is_integer(sequence) or sequence < 1 or sequence > stats.expected ->
        %{stats | invalid: stats.invalid + 1}

      not valid_payload? ->
        %{stats | invalid: stats.invalid + 1}

      Map.get(stats.seen, sequence) == true ->
        %{stats | duplicates: stats.duplicates + 1}

      true ->
        gap_ms =
          if stats.last_arrival_ms == nil,
            do: 0,
            else: max(arrival_ms - stats.last_arrival_ms, 0)

        out_of_order =
          if sequence == stats.last_sequence + 1,
            do: stats.out_of_order,
            else: stats.out_of_order + 1

        %{
          stats
          | seen: Map.put(stats.seen, sequence, true),
            last_sequence: sequence,
            first_arrival_ms: stats.first_arrival_ms || arrival_ms,
            last_arrival_ms: arrival_ms,
            max_interarrival_ms: max(stats.max_interarrival_ms, gap_ms),
            out_of_order: out_of_order
        }
    end
  end

  @doc "Return bounded summary data without the per-sample tracking map."
  def summary(stats) do
    received = map_size(stats.seen)
    duration_ms = elapsed(stats.started_at_ms, stats.finished_at_ms)
    sample_span_ms = elapsed(stats.first_arrival_ms, stats.last_arrival_ms)

    %{
      expected: stats.expected,
      received: received,
      missing: stats.expected - received,
      duplicates: stats.duplicates,
      out_of_order: stats.out_of_order,
      invalid: stats.invalid,
      started: stats.started,
      finished: stats.finished,
      duration_ms: duration_ms,
      sample_span_ms: sample_span_ms,
      throughput_milli_messages_per_second: throughput(received, duration_ms),
      max_interarrival_ms: stats.max_interarrival_ms
    }
  end

  @doc "Compare two producer summaries using only the Controller's local clock."
  def fairness(first, second) do
    %{
      delivery_ratio_gap_per_mille:
        abs(delivery_ratio_per_mille(first) - delivery_ratio_per_mille(second)),
      start_skew_ms: timestamp_gap(first.started_at_ms, second.started_at_ms),
      completion_skew_ms: timestamp_gap(first.finished_at_ms, second.finished_at_ms),
      active_overlap_ms:
        active_overlap(
          first.started_at_ms,
          first.finished_at_ms,
          second.started_at_ms,
          second.finished_at_ms
        ),
      max_interarrival_gap_ms: abs(first.max_interarrival_ms - second.max_interarrival_ms)
    }
  end

  defp elapsed(nil, _finished_ms), do: nil
  defp elapsed(_started_ms, nil), do: nil
  defp elapsed(started_ms, finished_ms), do: max(finished_ms - started_ms, 0)

  defp throughput(_received, nil), do: nil
  defp throughput(_received, 0), do: nil
  defp throughput(received, duration_ms), do: div(received * 1_000_000, duration_ms)

  defp delivery_ratio_per_mille(stats),
    do: div(map_size(stats.seen) * 1_000, stats.expected)

  defp timestamp_gap(nil, _second), do: nil
  defp timestamp_gap(_first, nil), do: nil
  defp timestamp_gap(first, second), do: abs(first - second)

  defp active_overlap(nil, _first_finished, _second_started, _second_finished), do: nil
  defp active_overlap(_first_started, nil, _second_started, _second_finished), do: nil
  defp active_overlap(_first_started, _first_finished, nil, _second_finished), do: nil
  defp active_overlap(_first_started, _first_finished, _second_started, nil), do: nil

  defp active_overlap(first_started, first_finished, second_started, second_finished) do
    max(min(first_finished, second_finished) - max(first_started, second_started), 0)
  end
end
