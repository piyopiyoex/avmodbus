defmodule RobotSim.EnduranceReport do
  @moduledoc """
  Controller / Drive / Sensorsのserial logからendurance指標を集計するhost専用moduleです。

  通常のconsole行は無視し、`modbus_robot_resource`、`modbus_robot_memory`、
  traffic完了、endurance、connection traceの機械可読な行だけを対象にします。
  """

  @connection_events [
    "stale_detected",
    "restart_deferred",
    "transport_resumed",
    "transport_ready",
    "restart_started",
    "kernel_stop_requested",
    "kernel_stop_completed",
    "kernel_stop_failed",
    "kernel_start_started",
    "kernel_start_succeeded",
    "kernel_start_failed",
    "restart_succeeded",
    "restart_failed",
    "restart_budget_exhausted",
    "remote_reconnected",
    "recovery_verified",
    "peer_maintained"
  ]

  @doc "role別logを集計します。`mode`は`:traffic`または`:recovery`を指定できます。"
  def analyze(logs, options \\ [])

  def analyze(logs, options) when is_map(logs) and is_list(options) do
    with {:ok, since} <- validate_timestamp(Keyword.get(options, :since)),
         {:ok, until} <- validate_timestamp(Keyword.get(options, :until)),
         {:ok, mode} <- validate_mode(Keyword.get(options, :mode)),
         :ok <- validate_window(since, until) do
      logs
      |> Enum.reduce(initial_report(), fn {_source, text}, report ->
        analyze_text(text, report, since, until)
      end)
      |> finalize(mode)
    end
  end

  def analyze(_logs, _options), do: {:error, :invalid_logs}

  defp analyze_text(text, report, since, until) when is_binary(text) do
    text
    |> String.split("\n")
    |> Enum.filter(&inside_window?(&1, since, until))
    |> Enum.reduce(report, &analyze_line/2)
  end

  defp analyze_text(_text, report, _since, _until),
    do: %{report | malformed_lines: report.malformed_lines + 1}

  defp validate_timestamp(nil), do: {:ok, nil}

  defp validate_timestamp(timestamp) when is_binary(timestamp) do
    with true <- Regex.match?(~r/^\d{2}:\d{2}:\d{2}\.\d{3}$/, timestamp),
         {:ok, _time} <- Time.from_iso8601(timestamp) do
      {:ok, timestamp}
    else
      _error -> {:error, :invalid_timestamp}
    end
  end

  defp validate_timestamp(_timestamp), do: {:error, :invalid_timestamp}

  defp validate_window(since, until) when is_binary(since) and is_binary(until) do
    if since <= until, do: :ok, else: {:error, :invalid_time_window}
  end

  defp validate_window(_since, _until), do: :ok

  defp validate_mode(nil), do: {:ok, :traffic}
  defp validate_mode(:traffic), do: {:ok, :traffic}
  defp validate_mode(:recovery), do: {:ok, :recovery}
  defp validate_mode("traffic"), do: {:ok, :traffic}
  defp validate_mode("recovery"), do: {:ok, :recovery}
  defp validate_mode(_mode), do: {:error, :invalid_mode}

  defp inside_window?(_line, nil, nil), do: true

  defp inside_window?(line, since, until) do
    case Regex.run(~r/^\[(\d{2}:\d{2}:\d{2}\.\d{3})\]/, line) do
      [_, timestamp] ->
        (is_nil(since) or timestamp >= since) and (is_nil(until) or timestamp <= until)

      _other ->
        false
    end
  end

  defp analyze_line(line, report) do
    cond do
      String.contains?(line, "modbus_robot_resource:") ->
        analyze_resource(line, report)

      String.contains?(line, "modbus_robot_memory:") ->
        analyze_remote_memory(line, report)

      String.contains?(line, "modbus_robot_multinode: concurrent traffic report") ->
        analyze_traffic(line, report)

      String.contains?(line, "modbus_robot_endurance: starting") ->
        analyze_endurance_start(line, report)

      String.contains?(line, "modbus_robot_endurance: run=") ->
        analyze_endurance_run(line, report)

      String.contains?(line, "modbus_robot_endurance: complete") ->
        analyze_endurance_complete(line, report)

      String.contains?(line, "modbus_robot_connection:") ->
        analyze_connection(line, report)

      true ->
        report
    end
  end

  defp analyze_resource(line, report) do
    fields = fields(line)

    with {:ok, peer} <- peer(Map.get(fields, "peer")),
         {:ok, minimum_free_heap_bytes} <- integer(fields, "minimum_free_heap_bytes"),
         {:ok, max_queued_bytes} <- integer(fields, "max_queued_bytes"),
         {:ok, max_outstanding} <- integer(fields, "max_outstanding"),
         {:ok, global_max_queued_bytes} <- integer(fields, "global_max_queued_bytes"),
         {:ok, global_max_queued_chunks} <- integer(fields, "global_max_queued_chunks"),
         {:ok, global_rejected} <- integer(fields, "global_rejected"),
         {:ok, transaction_failures} <- integer(fields, "transaction_failures") do
      controller = report.controller

      peer_report =
        controller.peers
        |> Map.fetch!(peer)
        |> update_resource_peer(
          minimum_free_heap_bytes,
          max_queued_bytes,
          max_outstanding,
          transaction_failures
        )

      next_controller = %{
        controller
        | samples: controller.samples + 1,
          minimum_free_heap_bytes:
            minimum(controller.minimum_free_heap_bytes, minimum_free_heap_bytes),
          max_global_queued_bytes:
            max(controller.max_global_queued_bytes, global_max_queued_bytes),
          max_global_queued_chunks:
            max(controller.max_global_queued_chunks, global_max_queued_chunks),
          global_rejected: max(controller.global_rejected, global_rejected),
          peers: Map.put(controller.peers, peer, peer_report)
      }

      %{report | controller: next_controller}
    else
      _error -> malformed(report)
    end
  end

  defp analyze_remote_memory(line, report) do
    fields = fields(line)

    with {:ok, role} <- remote_role(Map.get(fields, "role")),
         {:ok, free_heap_bytes} <- integer(fields, "free_heap_bytes"),
         {:ok, minimum_free_heap_bytes} <- integer(fields, "minimum_free_heap_bytes") do
      memory = Map.fetch!(report.remotes, role)

      next = %{
        memory
        | samples: memory.samples + 1,
          minimum_observed_free_heap_bytes:
            minimum(memory.minimum_observed_free_heap_bytes, free_heap_bytes),
          minimum_free_heap_bytes:
            minimum(memory.minimum_free_heap_bytes, minimum_free_heap_bytes)
      }

      %{report | remotes: Map.put(report.remotes, role, next)}
    else
      _error -> malformed(report)
    end
  end

  defp analyze_traffic(line, report) do
    case Map.get(fields(line), "outcome") do
      "complete" -> put_in(report, [:traffic, :complete], report.traffic.complete + 1)
      "timeout" -> put_in(report, [:traffic, :timeout], report.traffic.timeout + 1)
      nil -> malformed(report)
      _other -> put_in(report, [:traffic, :other], report.traffic.other + 1)
    end
  end

  defp analyze_endurance_start(line, report) do
    case run_fraction(Map.get(fields(line), "run")) do
      {:ok, _run, total} ->
        endurance = report.endurance

        %{
          report
          | endurance: %{
              endurance
              | planned_runs: max(endurance.planned_runs, total),
                started_runs: endurance.started_runs + 1
            }
        }

      :error ->
        malformed(report)
    end
  end

  defp analyze_endurance_complete(line, report) do
    case run_fraction(Map.get(fields(line), "run")) do
      {:ok, run, total} ->
        endurance = report.endurance

        %{
          report
          | endurance: %{
              endurance
              | planned_runs: max(endurance.planned_runs, total),
                completed_runs: max(endurance.completed_runs, run),
                finished: run == total
            }
        }

      :error ->
        malformed(report)
    end
  end

  defp analyze_endurance_run(line, report) do
    case run_fraction(Map.get(fields(line), "run")) do
      {:ok, run, total} ->
        endurance = report.endurance

        %{
          report
          | endurance: %{
              endurance
              | planned_runs: max(endurance.planned_runs, total),
                completed_runs: max(endurance.completed_runs, run)
            }
        }

      :error ->
        malformed(report)
    end
  end

  defp analyze_connection(line, report) do
    event = Map.get(fields(line), "event")

    if event in @connection_events do
      connections = Map.update!(report.connections, event, &(&1 + 1))

      connection_timestamps =
        case line_timestamp_ms(line) do
          nil ->
            report.connection_timestamps

          timestamp_ms ->
            Map.update(
              report.connection_timestamps,
              event,
              timestamp_ms,
              &min(&1, timestamp_ms)
            )
        end

      %{report | connections: connections, connection_timestamps: connection_timestamps}
    else
      report
    end
  end

  defp line_timestamp_ms(line) do
    case Regex.run(~r/^\[(\d{2}):(\d{2}):(\d{2})\.(\d{3})\]/, line) do
      [_, hour, minute, second, millisecond] ->
        ((String.to_integer(hour) * 60 + String.to_integer(minute)) * 60 +
           String.to_integer(second)) *
          1_000 + String.to_integer(millisecond)

      _other ->
        nil
    end
  end

  defp update_resource_peer(
         peer,
         minimum_free_heap_bytes,
         max_queued_bytes,
         max_outstanding,
         transaction_failures
       ) do
    %{
      peer
      | samples: peer.samples + 1,
        minimum_free_heap_bytes: minimum(peer.minimum_free_heap_bytes, minimum_free_heap_bytes),
        max_queued_bytes: max(peer.max_queued_bytes, max_queued_bytes),
        max_outstanding: max(peer.max_outstanding, max_outstanding),
        transaction_failures:
          peer.transaction_failures +
            counter_delta(peer.last_transaction_failures, transaction_failures),
        last_transaction_failures: transaction_failures
    }
  end

  defp counter_delta(nil, current), do: current
  defp counter_delta(previous, current) when current >= previous, do: current - previous
  defp counter_delta(_previous, current), do: current

  defp fields(line) do
    Regex.scan(~r/([a-z_]+)=([^\s]+)/, line, capture: :all_but_first)
    |> Enum.reduce(%{}, fn [key, value], acc -> Map.put(acc, key, value) end)
  end

  defp integer(fields, key) do
    case Integer.parse(Map.get(fields, key, "")) do
      {value, ""} when value >= 0 -> {:ok, value}
      _other -> :error
    end
  end

  defp run_fraction(nil), do: :error

  defp run_fraction(value) do
    case String.split(value, "/") do
      [run, total] ->
        with {run, ""} when run > 0 <- Integer.parse(run),
             {total, ""} when total > 0 <- Integer.parse(total) do
          {:ok, run, total}
        else
          _other -> :error
        end

      _other ->
        :error
    end
  end

  defp peer("drive"), do: {:ok, :drive}
  defp peer("sensors"), do: {:ok, :sensors}
  defp peer(_peer), do: :error

  defp remote_role("drive"), do: {:ok, :drive}
  defp remote_role("sensors"), do: {:ok, :sensors}
  defp remote_role(_role), do: :error

  defp minimum(nil, value), do: value
  defp minimum(current, value), do: min(current, value)
  defp malformed(report), do: %{report | malformed_lines: report.malformed_lines + 1}

  defp finalize(report, mode) do
    controller = %{
      report.controller
      | peers:
          Map.new(report.controller.peers, fn {role, peer} ->
            {role, Map.delete(peer, :last_transaction_failures)}
          end)
    }

    report = %{report | controller: controller}
    traffic = traffic_evaluation(report)
    recovery = recovery_evaluation(report.connections)
    observation = if complete_observation?(report), do: :complete, else: :incomplete
    logs = if report.malformed_lines == 0, do: :valid, else: :malformed

    successful =
      case mode do
        :traffic ->
          traffic == :passed and observation == :complete and logs == :valid and
            connection_recovery_complete?(report.connections)

        :recovery ->
          recovery == :passed and observation == :complete and logs == :valid
      end

    evaluation = %{
      mode: mode,
      successful: successful,
      traffic: traffic,
      recovery: recovery,
      observation: observation,
      logs: logs
    }

    {:ok,
     report
     |> Map.delete(:connection_timestamps)
     |> Map.put(:recovery_metrics, recovery_metrics(report.connection_timestamps))
     |> Map.put(:evaluation, evaluation)
     |> Map.put(:successful, successful)}
  end

  defp traffic_evaluation(report) do
    observed =
      report.traffic.complete + report.traffic.timeout + report.traffic.other > 0 or
        report.endurance.started_runs > 0

    cond do
      not observed ->
        :not_run

      report.traffic.complete > 0 and report.traffic.timeout == 0 and
        report.traffic.other == 0 and
          (report.endurance.planned_runs == 0 or report.endurance.finished) ->
        :passed

      true ->
        :failed
    end
  end

  defp recovery_evaluation(connections) do
    observed = Enum.any?(@connection_events, &(connections[&1] > 0))
    verified = connections["recovery_verified"]
    maintained = connections["peer_maintained"]
    restarted = connections["restart_succeeded"]
    reconnected = connections["remote_reconnected"]

    cond do
      not observed ->
        :not_run

      not connection_recovery_complete?(connections) ->
        :failed

      verified == 0 or maintained < verified ->
        :failed

      restarted > 0 and reconnected < restarted ->
        :failed

      true ->
        :passed
    end
  end

  defp recovery_metrics(timestamps) do
    %{
      transport_ready_to_restart_started_ms:
        elapsed_ms(timestamps, "transport_ready", "restart_started"),
      transport_ready_to_recovery_verified_ms:
        elapsed_ms(timestamps, "transport_ready", "recovery_verified"),
      restart_started_to_restart_succeeded_ms:
        elapsed_ms(timestamps, "restart_started", "restart_succeeded"),
      restart_succeeded_to_remote_reconnected_ms:
        elapsed_ms(timestamps, "restart_succeeded", "remote_reconnected")
    }
  end

  defp elapsed_ms(timestamps, from, to) do
    with from_ms when is_integer(from_ms) <- Map.get(timestamps, from),
         to_ms when is_integer(to_ms) <- Map.get(timestamps, to),
         true <- to_ms >= from_ms do
      to_ms - from_ms
    else
      _other -> nil
    end
  end

  defp connection_recovery_complete?(connections) do
    connections["kernel_stop_failed"] == 0 and
      connections["kernel_start_failed"] == 0 and
      connections["restart_failed"] == 0 and
      connections["restart_budget_exhausted"] == 0 and
      connections["restart_started"] == connections["restart_succeeded"]
  end

  defp complete_observation?(report) do
    report.controller.samples > 0 and report.remotes.drive.samples > 0 and
      report.remotes.sensors.samples > 0
  end

  defp initial_report do
    empty_peer = %{
      samples: 0,
      minimum_free_heap_bytes: nil,
      max_queued_bytes: 0,
      max_outstanding: 0,
      transaction_failures: 0,
      last_transaction_failures: nil
    }

    empty_remote = %{
      samples: 0,
      minimum_observed_free_heap_bytes: nil,
      minimum_free_heap_bytes: nil
    }

    %{
      traffic: %{complete: 0, timeout: 0, other: 0},
      endurance: %{planned_runs: 0, started_runs: 0, completed_runs: 0, finished: false},
      controller: %{
        samples: 0,
        minimum_free_heap_bytes: nil,
        max_global_queued_bytes: 0,
        max_global_queued_chunks: 0,
        global_rejected: 0,
        peers: %{drive: empty_peer, sensors: empty_peer}
      },
      remotes: %{drive: empty_remote, sensors: empty_remote},
      connections: Map.new(@connection_events, &{&1, 0}),
      connection_timestamps: %{},
      malformed_lines: 0
    }
  end
end
