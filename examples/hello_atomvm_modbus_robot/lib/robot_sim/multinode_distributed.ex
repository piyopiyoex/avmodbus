defmodule RobotSim.MultinodeDistributed do
  @moduledoc """
  Stage 3 three-node distributed Erlang probe over a shared Modbus RTU bus.

  The Controller owns one AVModbus client. Two FC-100 logical adapters share
  that client while retaining independent channel and byte-stream state.
  Drive and Sensors initiate their logical distribution connections so each
  remote node is bound to the correct Modbus Unit ID.
  """

  @compile {:no_warn_undefined, :net_kernel}

  alias AVModbus.Client
  alias DisterlProbe.{ModbusUART, Payload, Session}
  alias RobotSim.{ConcurrentTraffic, Drive, MultinodeStats, SensorMission, Sensors}

  @mode Application.compile_env(:robot_sim, :mode, :distributed)
  @role Application.compile_env(:robot_sim, :role, :controller)
  @serial Application.compile_env(:robot_sim, :serial, [])
  @unit_id Application.compile_env(:robot_sim, :unit_id, 1)
  @drive_unit_id Application.compile_env(:robot_sim, :drive_unit_id, 1)
  @sensors_unit_id Application.compile_env(:robot_sim, :sensors_unit_id, 2)
  @timeout_ms Application.compile_env(:robot_sim, :timeout_ms, 500)
  @bulk_timeout_ms Application.compile_env(:robot_sim, :bulk_timeout_ms, 2_000)
  @chunk_payload_bytes Application.compile_env(:robot_sim, :chunk_payload_bytes, 96)
  @max_queued_bytes Application.compile_env(:robot_sim, :max_queued_bytes, 8_192)
  @max_queued_chunks Application.compile_env(:robot_sim, :max_queued_chunks, 256)
  @poll_ms Application.compile_env(:robot_sim, :poll_ms, 20)
  @gap_ms Application.compile_env(:robot_sim, :multidrop_gap_ms, 20)
  @trace_transactions Application.compile_env(:robot_sim, :trace_transactions, false)
  @trace_queue Application.compile_env(:robot_sim, :trace_queue, false)
  @cookie Application.compile_env(:robot_sim, :cookie, "AtomVM")
  @probe_timeout_ms Application.compile_env(:robot_sim, :mission_timeout_ms, 60_000)
  @announce_ms Application.compile_env(:robot_sim, :multinode_announce_ms, 30_000)
  @health_check_ms Application.compile_env(:robot_sim, :multinode_health_check_ms, 5_000)
  @lease_ms Application.compile_env(:robot_sim, :multinode_lease_ms, 75_000)
  @soak_cycles Application.compile_env(:robot_sim, :multinode_soak_cycles, 0)
  @soak_payload_bytes Application.compile_env(:robot_sim, :multinode_soak_payload_bytes, 128)
  @soak_interval_ms Application.compile_env(:robot_sim, :multinode_soak_interval_ms, 250)
  @soak_retries Application.compile_env(:robot_sim, :multinode_soak_retries, 1)
  @traffic_samples Application.compile_env(:robot_sim, :multinode_traffic_samples, 0)
  @traffic_drive_interval_ms Application.compile_env(
                               :robot_sim,
                               :multinode_traffic_drive_interval_ms,
                               2_000
                             )
  @traffic_sensors_interval_ms Application.compile_env(
                                 :robot_sim,
                                 :multinode_traffic_sensors_interval_ms,
                                 1_000
                               )
  @traffic_payload_bytes Application.compile_env(:robot_sim, :multinode_traffic_payload_bytes, 16)
  @traffic_timeout_ms Application.compile_env(:robot_sim, :multinode_traffic_timeout_ms, 120_000)
  @traffic_settle_ms Application.compile_env(:robot_sim, :multinode_traffic_settle_ms, 30_000)
  @traffic_ack_timeout_ms Application.compile_env(
                            :robot_sim,
                            :multinode_traffic_ack_timeout_ms,
                            90_000
                          )
  @traffic_ack_retries Application.compile_env(:robot_sim, :multinode_traffic_ack_retries, 1)
  @sensor_mission_steps Application.compile_env(:robot_sim, :sensor_mission_steps, 3)
  @mission_retries Application.compile_env(:robot_sim, :mission_retries, 1)
  @drive_drop_first_reply_per_request Application.compile_env(
                                        :robot_sim,
                                        :drive_drop_first_reply_per_request,
                                        false
                                      )

  @controller_name :modbus_robot_controller
  @remote_name :modbus_robot_remote
  @drive_name :modbus_robot_drive
  @sensors_name :modbus_robot_sensors

  @doc "Start the configured Stage 3 role."
  @spec start() :: no_return()
  def start do
    case {@mode, @role} do
      {:multinode, :controller} -> start_controller()
      {:multinode, role} when role in [:drive, :sensors] -> start_remote(role)
      other -> halt("invalid multinode configuration", other)
    end
  end

  @doc "Return the fixed node identity used by a Stage 3 role."
  @spec identity(:controller | :drive | :sensors) :: node()
  def identity(:controller), do: :"controller@modbus.local"
  def identity(:drive), do: :"drive@modbus.local"
  def identity(:sensors), do: :"sensors@modbus.local"

  @doc "Return the Controller's logical stream targets in polling order."
  @spec targets(1..247, 1..247) :: [{:drive | :sensors, 1..247}]
  def targets(drive_unit_id \\ 1, sensors_unit_id \\ 2),
    do: [{:drive, drive_unit_id}, {:sensors, sensors_unit_id}]

  @doc "Return the alternating application-probe order for one soak cycle."
  @spec soak_targets(pos_integer()) :: [:drive | :sensors]
  def soak_targets(cycle) when is_integer(cycle) and cycle > 0 do
    if rem(cycle, 2) == 1, do: [:drive, :sensors], else: [:sensors, :drive]
  end

  @doc "Classify a remote readiness announcement against the Controller state."
  @spec classify_readiness(map(), :drive | :sensors, node(), pid(), pos_integer()) ::
          :new | :duplicate | :unexpected
  def classify_readiness(remotes, role, remote_node, pid, boot_id)
      when role in [:drive, :sensors] and is_pid(pid) and is_integer(boot_id) and boot_id > 0 do
    cond do
      remote_node != identity(role) -> :unexpected
      true -> classify_known_remote(Map.get(remotes, role), pid, boot_id)
    end
  end

  @doc "Expire remote readiness leases whose most recent heartbeat is too old."
  @spec expire_stale_remotes(map(), integer(), pos_integer()) ::
          {[:drive | :sensors], map()}
  def expire_stale_remotes(remotes, now_ms, lease_ms)
      when is_integer(now_ms) and is_integer(lease_ms) and lease_ms > 0 do
    {drive_expired, remotes} = expire_remote(remotes, :drive, now_ms, lease_ms)
    {sensors_expired, remotes} = expire_remote(remotes, :sensors, now_ms, lease_ms)
    {drive_expired ++ sensors_expired, remotes}
  end

  @doc "Apply a readiness announcement while waiting for one soak role."
  @spec soak_readiness_transition(
          map(),
          :drive | :sensors,
          :drive | :sensors,
          node(),
          pid(),
          pos_integer()
        ) ::
          {:retry | :continue | :duplicate | :unexpected, map()}
  def soak_readiness_transition(remotes, awaited_role, role, remote_node, pid, boot_id)
      when awaited_role in [:drive, :sensors] and role in [:drive, :sensors] and is_pid(pid) and
             is_integer(boot_id) and boot_id > 0 do
    case classify_readiness(remotes, role, remote_node, pid, boot_id) do
      :new ->
        action = if role == awaited_role, do: :retry, else: :continue
        {action, Map.put(remotes, role, %{pid: pid, boot_id: boot_id})}

      :duplicate ->
        {:duplicate, remotes}

      :unexpected ->
        {:unexpected, remotes}
    end
  end

  defp classify_known_remote(%{pid: pid, boot_id: boot_id}, pid, boot_id), do: :duplicate
  defp classify_known_remote(_remote, _pid, _boot_id), do: :new

  defp expire_remote(remotes, role, now_ms, lease_ms) do
    case Map.get(remotes, role) do
      %{last_seen_ms: last_seen_ms} when now_ms - last_seen_ms > lease_ms ->
        {[role], Map.put(remotes, role, nil)}

      _remote ->
        {[], remotes}
    end
  end

  defp start_controller do
    case Client.start_link(
           transport: :rtu,
           serial: @serial,
           gap: @gap_ms,
           timeout: @timeout_ms
         ) do
      {:ok, client} -> start_controller_adapters(client)
      {:error, reason} -> halt("shared Modbus client start failed", reason)
    end
  end

  defp start_controller_adapters(client) do
    case open_client_adapter(client, @drive_unit_id) do
      {:ok, drive_uart} ->
        case open_client_adapter(client, @sensors_unit_id) do
          {:ok, sensors_uart} ->
            start_controller_distribution(client, drive_uart, sensors_uart)

          {:error, reason} ->
            ModbusUART.close(drive_uart)
            Client.stop(client)
            halt("Sensors adapter start failed", reason)
        end

      {:error, reason} ->
        Client.stop(client)
        halt("Drive adapter start failed", reason)
    end
  end

  defp start_controller_distribution(client, drive_uart, sensors_uart) do
    IO.puts("modbus_robot_multinode: waiting for Drive and Sensors FC-100 peers")
    wait_for_peers([{:drive, drive_uart}, {:sensors, sensors_uart}])

    ports = [
      uart_options(:client, @drive_unit_id, existing: drive_uart),
      uart_options(:client, @sensors_unit_id, existing: sensors_uart)
    ]

    case :net_kernel.start(identity(:controller), dist_options(ports)) do
      {:ok, _pid} ->
        :ok = :net_kernel.set_cookie(@cookie)
        true = :erlang.register(@controller_name, self())
        IO.puts("modbus_robot_multinode: Controller distribution ready with 2 streams")

        await_remotes(
          %{drive: nil, sensors: nil},
          %{drive: drive_uart, sensors: sensors_uart}
        )

      other ->
        ModbusUART.close(drive_uart)
        ModbusUART.close(sensors_uart)
        Client.stop(client)
        halt("Controller net_kernel start failed", other)
    end
  end

  defp start_remote(role) do
    ports = [uart_options(:server, @unit_id)]

    case :net_kernel.start(identity(role), dist_options(ports)) do
      {:ok, _pid} ->
        :ok = :net_kernel.set_cookie(@cookie)
        start_role_process(role)
        true = :erlang.register(@remote_name, self())
        IO.puts("modbus_robot_multinode: #{role} distribution ready unit=#{@unit_id}")
        remote_loop(role, Session.new_id())

      other ->
        halt("#{role} net_kernel start failed", other)
    end
  end

  defp start_role_process(:drive) do
    {:ok, _drive} =
      Drive.start_link(
        name: @drive_name,
        drop_first_reply_per_request: @drive_drop_first_reply_per_request
      )

    IO.puts("modbus_robot_multinode: Drive process registered as #{inspect(@drive_name)}")
  end

  defp start_role_process(:sensors) do
    {:ok, _sensors} = Sensors.start_link(name: @sensors_name)
    IO.puts("modbus_robot_multinode: Sensors process registered as #{inspect(@sensors_name)}")
  end

  defp remote_loop(role, boot_id) do
    announce(role, boot_id)

    receive do
      {:multinode_ack, ^role} ->
        IO.puts("modbus_robot_multinode: #{role} acknowledged by Controller")
        connected_remote_loop(role, boot_id)

      {:multinode_probe, from, reference} when is_pid(from) ->
        send(from, {:multinode_probe_reply, reference, role, node()})
        remote_loop(role, boot_id)

      {:multinode_soak, from, reference, id, payload}
      when is_pid(from) and is_binary(payload) ->
        reply_to_soak(from, reference, id, role, payload)
        remote_loop(role, boot_id)

      {:robot_traffic_start, collector, run_id, samples, interval_ms, payload_bytes,
       ack_timeout_ms, ack_retries}
      when is_pid(collector) ->
        ConcurrentTraffic.start_producer(
          collector,
          role,
          run_id,
          samples,
          interval_ms,
          payload_bytes,
          ack_timeout_ms,
          ack_retries
        )

        remote_loop(role, boot_id)
    after
      2_000 -> remote_loop(role, boot_id)
    end
  end

  defp connected_remote_loop(role, boot_id) do
    receive do
      {:multinode_ack, ^role} ->
        connected_remote_loop(role, boot_id)

      {:multinode_probe, from, reference} when is_pid(from) ->
        send(from, {:multinode_probe_reply, reference, role, node()})
        connected_remote_loop(role, boot_id)

      {:multinode_soak, from, reference, id, payload}
      when is_pid(from) and is_binary(payload) ->
        reply_to_soak(from, reference, id, role, payload)
        connected_remote_loop(role, boot_id)

      {:robot_traffic_start, collector, run_id, samples, interval_ms, payload_bytes,
       ack_timeout_ms, ack_retries}
      when is_pid(collector) ->
        ConcurrentTraffic.start_producer(
          collector,
          role,
          run_id,
          samples,
          interval_ms,
          payload_bytes,
          ack_timeout_ms,
          ack_retries
        )

        connected_remote_loop(role, boot_id)
    after
      @announce_ms ->
        announce(role, boot_id)
        connected_remote_loop(role, boot_id)
    end
  end

  defp announce(role, boot_id) do
    send(
      {@controller_name, identity(:controller)},
      {:multinode_ready, role, node(), self(), boot_id}
    )
  end

  defp await_remotes(
         %{
           drive: %{pid: drive_pid} = drive,
           sensors: %{pid: sensors_pid} = sensors
         },
         adapters
       )
       when is_pid(drive_pid) and is_pid(sensors_pid) do
    IO.puts("modbus_robot_multinode: both remote nodes connected")

    with :ok <- probe_remote(:drive, identity(:drive)),
         :ok <- probe_remote(:sensors, identity(:sensors)),
         :ok <- run_sensor_mission() do
      IO.puts("modbus_robot_multinode: complete Drive and Sensors remote messaging")
      remotes = run_soak_if_enabled(%{drive: drive, sensors: sensors})
      start_traffic_if_enabled(adapters)
      controller_loop(remotes, adapters)
    else
      {:error, reason} -> halt("remote initialization failed", reason)
    end
  end

  defp await_remotes(remotes, adapters) do
    receive do
      {:multinode_ready, role, remote_node, pid, boot_id}
      when role in [:drive, :sensors] and is_pid(pid) and is_integer(boot_id) and boot_id > 0 ->
        case classify_readiness(remotes, role, remote_node, pid, boot_id) do
          :new ->
            send(pid, {:multinode_ack, role})
            IO.puts("modbus_robot_multinode: connected role=#{role} node=#{inspect(remote_node)}")
            await_remotes(track_remote(remotes, role, pid, boot_id), adapters)

          :duplicate ->
            send(pid, {:multinode_ack, role})
            await_remotes(track_remote(remotes, role, pid, boot_id), adapters)

          :unexpected ->
            log_unexpected_node(role, remote_node)
            await_remotes(remotes, adapters)
        end
    after
      @probe_timeout_ms -> halt("timed out waiting for remote nodes", remotes)
    end
  end

  defp controller_loop(remotes, adapters) do
    receive do
      {:robot_traffic_complete, run_id, summary} ->
        log_adapter_metrics("after", adapters)
        schedule_settled_metrics(run_id)

        IO.puts(
          "modbus_robot_multinode: concurrent traffic report run=#{run_id} " <>
            "outcome=#{summary.outcome}"
        )

        controller_loop(remotes, adapters)

      {:robot_traffic_metrics_settled, run_id} ->
        log_adapter_metrics("settled", adapters)
        IO.puts("modbus_robot_metrics: settled run=#{run_id}")
        controller_loop(remotes, adapters)

      {:multinode_ready, role, remote_node, pid, boot_id}
      when role in [:drive, :sensors] and is_pid(pid) and is_integer(boot_id) and boot_id > 0 ->
        case classify_readiness(remotes, role, remote_node, pid, boot_id) do
          :duplicate ->
            send(pid, {:multinode_ack, role})
            controller_loop(track_remote(remotes, role, pid, boot_id), adapters)

          :new ->
            send(pid, {:multinode_ack, role})

            next_remotes = track_remote(remotes, role, pid, boot_id)

            IO.puts(
              "modbus_robot_multinode: reconnected role=#{role} node=#{inspect(remote_node)}"
            )

            verify_recovery(role)
            controller_loop(next_remotes, adapters)

          :unexpected ->
            log_unexpected_node(role, remote_node)
            controller_loop(remotes, adapters)
        end
    after
      @health_check_ms ->
        {expired_roles, next_remotes} =
          expire_stale_remotes(remotes, monotonic_ms(), @lease_ms)

        log_expired_roles(expired_roles)
        controller_loop(next_remotes, adapters)
    end
  end

  defp verify_recovery(restarted_role) do
    peer_role = if restarted_role == :drive, do: :sensors, else: :drive

    with :ok <- probe_remote(restarted_role, identity(restarted_role)),
         :ok <- probe_remote(peer_role, identity(peer_role)) do
      IO.puts(
        "modbus_robot_multinode: recovery complete restarted=#{restarted_role} peer=#{peer_role}"
      )
    else
      {:error, reason} ->
        IO.puts("modbus_robot_multinode: recovery probe failed #{inspect(reason)}")
    end
  end

  defp log_unexpected_node(role, remote_node) do
    IO.puts(
      "modbus_robot_multinode: ignored unexpected node role=#{role} node=#{inspect(remote_node)}"
    )
  end

  defp track_remote(remotes, role, pid, boot_id) do
    Map.put(remotes, role, %{
      pid: pid,
      boot_id: boot_id,
      last_seen_ms: monotonic_ms()
    })
  end

  defp monotonic_ms, do: :erlang.monotonic_time(:millisecond)

  defp log_expired_roles([]), do: :ok

  defp log_expired_roles([role | rest]) do
    IO.puts("modbus_robot_multinode: readiness lease expired role=#{role}")
    log_expired_roles(rest)
  end

  defp probe_remote(role, remote_node) do
    reference = make_ref()
    send({@remote_name, remote_node}, {:multinode_probe, self(), reference})

    receive do
      {:multinode_probe_reply, ^reference, ^role, ^remote_node} ->
        IO.puts("modbus_robot_multinode: probe reply role=#{role} node=#{inspect(remote_node)}")
        :ok
    after
      @probe_timeout_ms -> {:error, {:probe_timeout, role, remote_node}}
    end
  end

  defp run_sensor_mission do
    case SensorMission.run(
           {@sensors_name, identity(:sensors)},
           {@drive_name, identity(:drive)},
           steps: @sensor_mission_steps,
           first_request_id: Session.new_id(),
           timeout_ms: @probe_timeout_ms,
           max_retries: @mission_retries,
           trace: true
         ) do
      {:ok, result} ->
        IO.puts("modbus_robot_multinode: sensor mission complete state=#{inspect(result.rover)}")

        :ok

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp start_traffic_if_enabled(adapters) do
    if @traffic_samples > 0 do
      reset_adapter_metrics(adapters)
      log_adapter_metrics("before", adapters)

      targets = [
        {:drive, {@remote_name, identity(:drive)}},
        {:sensors, {@remote_name, identity(:sensors)}}
      ]

      ConcurrentTraffic.start(self(), targets,
        samples: @traffic_samples,
        drive_interval_ms: @traffic_drive_interval_ms,
        sensors_interval_ms: @traffic_sensors_interval_ms,
        payload_bytes: @traffic_payload_bytes,
        timeout_ms: @traffic_timeout_ms,
        ack_timeout_ms: @traffic_ack_timeout_ms,
        ack_retries: @traffic_ack_retries
      )
    end
  end

  defp reset_adapter_metrics(adapters) do
    :ok = ModbusUART.reset_metrics(adapters.drive)
    :ok = ModbusUART.reset_metrics(adapters.sensors)
  end

  defp log_adapter_metrics(phase, adapters) do
    log_adapter_metric(phase, :drive, adapters.drive)
    log_adapter_metric(phase, :sensors, adapters.sensors)
  end

  defp log_adapter_metric(phase, role, adapter) do
    snapshot = ModbusUART.metrics_snapshot(adapter)

    IO.puts("modbus_robot_metrics: phase=#{phase} role=#{role} snapshot=#{inspect(snapshot)}")
  end

  defp schedule_settled_metrics(_run_id) when @traffic_settle_ms == 0, do: :ok

  defp schedule_settled_metrics(run_id) do
    Process.send_after(self(), {:robot_traffic_metrics_settled, run_id}, @traffic_settle_ms)
    :ok
  end

  defp run_soak_if_enabled(remotes) do
    if @soak_cycles > 0, do: run_soak(remotes), else: remotes
  end

  defp run_soak(remotes) do
    payload = Payload.build(@soak_payload_bytes)
    started_at = :erlang.monotonic_time(:millisecond)

    IO.puts(
      "modbus_robot_multinode: soak start cycles=#{@soak_cycles} payload_bytes=#{@soak_payload_bytes}"
    )

    stats = %{
      drive: MultinodeStats.new(),
      sensors: MultinodeStats.new()
    }

    {final_stats, final_remotes} = run_soak_cycle(1, payload, stats, remotes)
    elapsed_ms = :erlang.monotonic_time(:millisecond) - started_at
    summary = MultinodeStats.fairness(final_stats.drive, final_stats.sensors)

    IO.puts(
      "modbus_robot_multinode: soak complete cycles=#{@soak_cycles} " <>
        "payload_bytes=#{@soak_payload_bytes} elapsed_ms=#{elapsed_ms} summary=#{inspect(summary)}"
    )

    final_remotes
  end

  defp run_soak_cycle(cycle, _payload, stats, remotes) when cycle > @soak_cycles,
    do: {stats, remotes}

  defp run_soak_cycle(cycle, payload, stats, remotes) do
    {next_stats, next_remotes} =
      run_soak_targets(cycle, soak_targets(cycle), payload, stats, remotes)

    Process.sleep(@soak_interval_ms)
    run_soak_cycle(cycle + 1, payload, next_stats, next_remotes)
  end

  defp run_soak_targets(_cycle, [], _payload, stats, remotes), do: {stats, remotes}

  defp run_soak_targets(cycle, [role | rest], payload, stats, remotes) do
    id = {cycle, role}

    case soak_probe(role, identity(role), id, payload, remotes) do
      {:ok, rtt_ms, next_remotes} ->
        IO.puts(
          "modbus_robot_multinode: soak cycle=#{cycle} role=#{role} " <>
            "rtt_ms=#{rtt_ms} payload_bytes=#{byte_size(payload)}"
        )

        role_stats = MultinodeStats.record_success(Map.get(stats, role), rtt_ms)
        next_stats = Map.put(stats, role, role_stats)
        run_soak_targets(cycle, rest, payload, next_stats, next_remotes)

      {:error, reason, next_remotes} ->
        IO.puts(
          "modbus_robot_multinode: soak cycle=#{cycle} role=#{role} failed=#{inspect(reason)}"
        )

        role_stats = MultinodeStats.record_failure(Map.get(stats, role))
        next_stats = Map.put(stats, role, role_stats)
        run_soak_targets(cycle, rest, payload, next_stats, next_remotes)
    end
  end

  defp soak_probe(role, remote_node, id, payload, remotes) do
    started_at = :erlang.monotonic_time(:millisecond)
    do_soak_probe(role, remote_node, id, payload, remotes, @soak_retries, started_at)
  end

  defp do_soak_probe(role, remote_node, id, payload, remotes, retries, started_at) do
    reference = make_ref()
    send({@remote_name, remote_node}, {:multinode_soak, self(), reference, id, payload})
    deadline = :erlang.monotonic_time(:millisecond) + @probe_timeout_ms

    case await_soak_reply(role, remote_node, id, payload, reference, remotes, deadline) do
      {:ok, next_remotes} ->
        {:ok, :erlang.monotonic_time(:millisecond) - started_at, next_remotes}

      {:retry, next_remotes} when retries > 0 ->
        IO.puts(
          "modbus_robot_multinode: soak retry role=#{role} id=#{inspect(id)} " <>
            "remaining=#{retries - 1}"
        )

        do_soak_probe(
          role,
          remote_node,
          id,
          payload,
          next_remotes,
          retries - 1,
          started_at
        )

      {:retry, next_remotes} ->
        {:error, {:reconnect_retry_exhausted, role, id}, next_remotes}

      {:error, reason, next_remotes} ->
        {:error, reason, next_remotes}
    end
  end

  defp await_soak_reply(role, remote_node, id, payload, reference, remotes, deadline) do
    remaining_ms = max(deadline - :erlang.monotonic_time(:millisecond), 0)

    receive do
      {:multinode_soak_reply, ^reference, ^role, ^remote_node, ^id, reply_payload}
      when is_binary(reply_payload) ->
        if reply_payload == payload do
          {:ok, remotes}
        else
          {:error, {:invalid_payload, role, id, byte_size(reply_payload)}, remotes}
        end

      {:multinode_soak_reply, ^reference, ^role, ^remote_node, ^id, _reply_payload} ->
        {:error, {:invalid_payload, role, id, :not_binary}, remotes}

      {:multinode_soak_error, ^reference, ^role, ^remote_node, ^id, reason} ->
        {:error, reason, remotes}

      {:multinode_ready, ready_role, ready_node, pid, boot_id}
      when ready_role in [:drive, :sensors] and is_pid(pid) and is_integer(boot_id) and
             boot_id > 0 ->
        case soak_readiness_transition(
               remotes,
               role,
               ready_role,
               ready_node,
               pid,
               boot_id
             ) do
          {:duplicate, next_remotes} ->
            send(pid, {:multinode_ack, ready_role})

            next_remotes =
              track_remote(next_remotes, ready_role, pid, boot_id)

            await_soak_reply(role, remote_node, id, payload, reference, next_remotes, deadline)

          {action, next_remotes} when action in [:retry, :continue] ->
            send(pid, {:multinode_ack, ready_role})

            next_remotes = track_remote(next_remotes, ready_role, pid, boot_id)

            IO.puts(
              "modbus_robot_multinode: reconnected during soak role=#{ready_role} " <>
                "node=#{inspect(ready_node)}"
            )

            if action == :retry do
              {:retry, next_remotes}
            else
              await_soak_reply(
                role,
                remote_node,
                id,
                payload,
                reference,
                next_remotes,
                deadline
              )
            end

          {:unexpected, next_remotes} ->
            log_unexpected_node(ready_role, ready_node)
            await_soak_reply(role, remote_node, id, payload, reference, next_remotes, deadline)
        end
    after
      remaining_ms -> {:error, {:soak_timeout, role, id}, remotes}
    end
  end

  defp reply_to_soak(from, reference, id, role, payload) do
    if Payload.valid?(payload) do
      send(from, {:multinode_soak_reply, reference, role, node(), id, payload})
    else
      send(from, {:multinode_soak_error, reference, role, node(), id, :invalid_payload})
    end
  end

  defp open_client_adapter(client, unit_id) do
    case ModbusUART.open(uart_options(:client, unit_id, client: client)) do
      pid when is_pid(pid) -> {:ok, pid}
      {:error, _reason} = error -> error
    end
  end

  defp wait_for_peers([]), do: :ok

  defp wait_for_peers([{role, uart} | rest]) do
    if ModbusUART.peer_ready?(uart) do
      IO.puts("modbus_robot_multinode: FC-100 peer ready role=#{role}")
      wait_for_peers(rest)
    else
      Process.sleep(max(@poll_ms, 1))
      wait_for_peers([{role, uart} | rest])
    end
  end

  defp dist_options(ports) do
    %{
      name_domain: :longnames,
      proto_dist: :serial_dist,
      avm_dist_opts: %{
        uart_ports: ports,
        uart_module: ModbusUART
      }
    }
  end

  defp uart_options(role, unit_id, extra \\ []) do
    extra ++
      [
        role: role,
        serial: @serial,
        unit_id: unit_id,
        timeout_ms: @timeout_ms,
        bulk_timeout_ms: @bulk_timeout_ms,
        chunk_payload_bytes: @chunk_payload_bytes,
        max_queued_bytes: @max_queued_bytes,
        max_queued_chunks: @max_queued_chunks,
        fault_drop_responses: 0,
        fault_min_payload_bytes: 96,
        fault_after_ms: 10_000,
        poll_ms: @poll_ms,
        trace_transactions: @trace_transactions,
        trace_queue: @trace_queue
      ]
  end

  defp halt(message, reason) do
    IO.puts("modbus_robot_multinode: #{message} #{inspect(reason)}")
    Process.sleep(:infinity)
  end
end
