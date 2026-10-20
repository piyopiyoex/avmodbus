defmodule RobotSim.ConcurrentTraffic do
  @moduledoc """
  Opt-in concurrent application-traffic probe for the three-node robot.

  Drive and Sensors each run an independent producer. A separate Controller
  collector observes arrivals, leaving the Controller's readiness lease loop
  free to process heartbeats. Each producer keeps one message in flight and
  advances only after a Controller application ACK. No shared clocks or
  persistent state are assumed.
  """

  alias DisterlProbe.{Payload, Session}
  alias RobotSim.TrafficStats

  @roles [:drive, :sensors]
  @max_samples 256
  @default_ack_timeout_ms 90_000
  @default_ack_retries 1

  @doc "Start a Controller collector without blocking its caller."
  def start(parent, targets, options) when is_pid(parent) and is_list(targets) do
    spawn(fn -> collect_run(parent, targets, options) end)
  end

  @doc "Start a standalone remote producer, without blocking its remote receive loop."
  def start_producer(collector, role, run_id, count, interval_ms, payload_bytes)
      when is_pid(collector) do
    start_producer(
      collector,
      role,
      run_id,
      count,
      interval_ms,
      payload_bytes,
      @default_ack_timeout_ms,
      @default_ack_retries
    )
  end

  @doc false
  def start_producer(
        collector,
        role,
        run_id,
        count,
        interval_ms,
        payload_bytes,
        ack_timeout_ms,
        ack_retries
      )
      when is_pid(collector) do
    start_producer(
      collector,
      role,
      run_id,
      count,
      interval_ms,
      payload_bytes,
      ack_timeout_ms,
      ack_retries,
      nil
    )
  end

  @doc false
  def start_producer(
        collector,
        role,
        run_id,
        count,
        interval_ms,
        payload_bytes,
        ack_timeout_ms,
        ack_retries,
        recovery_target
      )
      when is_pid(collector) and role in @roles and is_integer(run_id) and run_id > 0 and
             is_integer(count) and count > 0 and count <= @max_samples and
             is_integer(interval_ms) and
             interval_ms > 0 and is_integer(payload_bytes) and payload_bytes >= 0 and
             payload_bytes <= 128 and is_integer(ack_timeout_ms) and ack_timeout_ms > 0 and
             is_integer(ack_retries) and ack_retries >= 0 and
             (is_pid(recovery_target) or recovery_target == nil) do
    spawn(fn ->
      payload = Payload.build(payload_bytes)

      result =
        with :ok <-
               send_with_ack(
                 collector,
                 {:robot_traffic_started, self(), role, run_id},
                 {:robot_traffic_ack, :started, role, run_id},
                 ack_timeout_ms,
                 ack_retries,
                 :started,
                 recovery_target,
                 role,
                 run_id
               ),
             :ok <-
               send_samples(
                 collector,
                 role,
                 run_id,
                 count,
                 interval_ms,
                 payload,
                 1,
                 ack_timeout_ms,
                 ack_retries,
                 recovery_target
               ) do
          send_with_ack(
            collector,
            {:robot_traffic_finished, self(), role, run_id},
            {:robot_traffic_ack, :finished, role, run_id},
            ack_timeout_ms,
            ack_retries,
            :finished,
            recovery_target,
            role,
            run_id
          )
        end

      log_producer_failure(role, run_id, result)
    end)
  end

  defp send_samples(
         _collector,
         _role,
         _run_id,
         count,
         _interval_ms,
         _payload,
         sequence,
         _ack_timeout_ms,
         _ack_retries,
         _recovery_target
       )
       when sequence > count,
       do: :ok

  defp send_samples(
         collector,
         role,
         run_id,
         count,
         interval_ms,
         payload,
         sequence,
         ack_timeout_ms,
         ack_retries,
         recovery_target
       ) do
    result =
      send_with_ack(
        collector,
        {:robot_traffic_sample, self(), role, run_id, sequence, payload},
        {:robot_traffic_ack, :sample, role, run_id, sequence},
        ack_timeout_ms,
        ack_retries,
        {:sample, sequence},
        recovery_target,
        role,
        run_id
      )

    if result == :ok and sequence < count do
      Process.sleep(interval_ms)

      send_samples(
        collector,
        role,
        run_id,
        count,
        interval_ms,
        payload,
        sequence + 1,
        ack_timeout_ms,
        ack_retries,
        recovery_target
      )
    else
      result
    end
  end

  defp send_with_ack(
         collector,
         message,
         expected_ack,
         ack_timeout_ms,
         retries_left,
         context,
         recovery_target,
         role,
         run_id
       ) do
    send(collector, message)

    receive do
      ^expected_ack ->
        :ok
    after
      ack_timeout_ms ->
        retry_after_ack_timeout(
          collector,
          message,
          expected_ack,
          ack_timeout_ms,
          retries_left,
          context,
          recovery_target,
          role,
          run_id
        )
    end
  end

  defp retry_after_ack_timeout(
         _collector,
         _message,
         _expected_ack,
         _ack_timeout_ms,
         0,
         context,
         _recovery_target,
         _role,
         _run_id
       ),
       do: {:error, {:ack_timeout, context}}

  defp retry_after_ack_timeout(
         collector,
         message,
         expected_ack,
         ack_timeout_ms,
         retries_left,
         context,
         recovery_target,
         role,
         run_id
       ) do
    IO.puts(
      "modbus_robot_traffic: ACK timeout context=#{inspect(context)}; " <>
        "retrying remaining=#{retries_left}"
    )

    notify_recovery_target(recovery_target, role, run_id, context)

    send_with_ack(
      collector,
      message,
      expected_ack,
      ack_timeout_ms,
      retries_left - 1,
      context,
      nil,
      role,
      run_id
    )
  end

  defp notify_recovery_target(nil, _role, _run_id, _context), do: :ok

  defp notify_recovery_target(target, role, run_id, context) do
    send(target, {:robot_traffic_ack_timeout, self(), role, run_id, context})
    :ok
  end

  defp log_producer_failure(_role, _run_id, :ok), do: :ok

  defp log_producer_failure(role, run_id, {:error, reason}) do
    IO.puts(
      "modbus_robot_traffic: producer stopped role=#{role} run=#{run_id} " <>
        "reason=#{inspect(reason)}"
    )
  end

  defp collect_run(parent, targets, options) do
    count = Keyword.fetch!(options, :samples)
    payload_bytes = Keyword.fetch!(options, :payload_bytes)
    timeout_ms = Keyword.fetch!(options, :timeout_ms)
    ack_timeout_ms = Keyword.get(options, :ack_timeout_ms, @default_ack_timeout_ms)
    ack_retries = Keyword.get(options, :ack_retries, @default_ack_retries)
    run_id = Session.new_id()
    expected_payload = Payload.build(payload_bytes)
    started_ms = now_ms()

    stats = %{drive: TrafficStats.new(count), sensors: TrafficStats.new(count)}

    start_producers(targets, run_id, count, payload_bytes, options)

    IO.puts(
      "modbus_robot_traffic: start run=#{run_id} samples_per_role=#{count} " <>
        "payload_bytes=#{payload_bytes} in_flight_per_role=1 " <>
        "ack_timeout_ms=#{ack_timeout_ms} ack_retries=#{ack_retries}"
    )

    {result, final_stats} =
      receive_samples(stats, run_id, expected_payload, started_ms + timeout_ms)

    summary = %{
      outcome: result,
      elapsed_ms: now_ms() - started_ms,
      drive: TrafficStats.summary(final_stats.drive),
      sensors: TrafficStats.summary(final_stats.sensors),
      fairness: TrafficStats.fairness(final_stats.drive, final_stats.sensors)
    }

    IO.puts("modbus_robot_traffic: complete run=#{run_id} summary=#{inspect(summary)}")
    send(parent, {:robot_traffic_complete, run_id, summary})
  end

  defp interval_key(:drive), do: :drive_interval_ms
  defp interval_key(:sensors), do: :sensors_interval_ms

  defp start_producers([], _run_id, _count, _payload_bytes, _options), do: :ok

  defp start_producers([{role, target} | rest], run_id, count, payload_bytes, options) do
    interval_ms = Keyword.fetch!(options, interval_key(role))
    ack_timeout_ms = Keyword.get(options, :ack_timeout_ms, @default_ack_timeout_ms)
    ack_retries = Keyword.get(options, :ack_retries, @default_ack_retries)

    send(
      target,
      {:robot_traffic_start, self(), run_id, count, interval_ms, payload_bytes, ack_timeout_ms,
       ack_retries}
    )

    start_producers(rest, run_id, count, payload_bytes, options)
  end

  defp receive_samples(
         %{drive: %{finished: true}, sensors: %{finished: true}} = stats,
         _run_id,
         _payload,
         _deadline
       ),
       do: {:complete, stats}

  defp receive_samples(stats, run_id, expected_payload, deadline) do
    remaining_ms = max(deadline - now_ms(), 0)

    receive do
      {:robot_traffic_started, producer, role, ^run_id}
      when is_pid(producer) and role in @roles ->
        send(producer, {:robot_traffic_ack, :started, role, run_id})
        next = Map.put(stats, role, TrafficStats.started(Map.get(stats, role), now_ms()))
        receive_samples(next, run_id, expected_payload, deadline)

      {:robot_traffic_sample, producer, role, ^run_id, sequence, payload}
      when is_pid(producer) and role in @roles ->
        arrival_ms = now_ms()

        next =
          Map.put(
            stats,
            role,
            TrafficStats.record(
              Map.get(stats, role),
              sequence,
              payload == expected_payload,
              arrival_ms
            )
          )

        send(producer, {:robot_traffic_ack, :sample, role, run_id, sequence})
        receive_samples(next, run_id, expected_payload, deadline)

      {:robot_traffic_finished, producer, role, ^run_id}
      when is_pid(producer) and role in @roles ->
        send(producer, {:robot_traffic_ack, :finished, role, run_id})
        next = Map.put(stats, role, TrafficStats.finished(Map.get(stats, role), now_ms()))
        receive_samples(next, run_id, expected_payload, deadline)
    after
      remaining_ms -> {:timeout, stats}
    end
  end

  defp now_ms, do: :erlang.monotonic_time(:millisecond)
end
