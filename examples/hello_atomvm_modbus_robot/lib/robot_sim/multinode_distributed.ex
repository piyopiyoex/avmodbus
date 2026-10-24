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
  alias DisterlProbe.{MemorySnapshot, ModbusUART, Payload, PollScheduler, QueueBudget, Session}

  alias RobotSim.{
    ConcurrentTraffic,
    ConnectionTrace,
    Drive,
    Endurance,
    MissionWorker,
    MultinodeStats,
    RecoveryWorker,
    RemoteHealth,
    Sensors
  }

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
  @global_max_queued_bytes Application.compile_env(
                             :robot_sim,
                             :multinode_global_max_queued_bytes,
                             8_192
                           )
  @global_max_queued_chunks Application.compile_env(
                              :robot_sim,
                              :multinode_global_max_queued_chunks,
                              256
                            )
  @fault_drop_responses Application.compile_env(:robot_sim, :fault_drop_responses, 0)
  @fault_min_payload_bytes Application.compile_env(:robot_sim, :fault_min_payload_bytes, 96)
  @fault_after_ms Application.compile_env(:robot_sim, :fault_after_ms, 10_000)
  @fault_rearm_on_restart Application.compile_env(
                            :robot_sim,
                            :fault_rearm_on_restart,
                            false
                          )
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
  @traffic_runs Application.compile_env(:robot_sim, :multinode_traffic_runs, 1)
  @traffic_idle_ms Application.compile_env(:robot_sim, :multinode_traffic_idle_ms, 0)
  @metrics_interval_ms Application.compile_env(:robot_sim, :multinode_metrics_interval_ms, 0)
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
  @traffic_start_delay_ms Application.compile_env(
                            :robot_sim,
                            :multinode_traffic_start_delay_ms,
                            0
                          )
  @traffic_ack_timeout_ms Application.compile_env(
                            :robot_sim,
                            :multinode_traffic_ack_timeout_ms,
                            90_000
                          )
  @traffic_ack_retries Application.compile_env(:robot_sim, :multinode_traffic_ack_retries, 1)
  @restart_on_traffic_ack_timeout Application.compile_env(
                                    :robot_sim,
                                    :multinode_restart_on_traffic_ack_timeout,
                                    false
                                  )
  @remote_health_enabled Application.compile_env(
                           :robot_sim,
                           :multinode_remote_health_enabled,
                           false
                         )
  @remote_health_trace Application.compile_env(
                         :robot_sim,
                         :multinode_remote_health_trace,
                         false
                       )
  @connection_trace Application.compile_env(
                      :robot_sim,
                      :multinode_connection_trace,
                      false
                    )
  @initial_recovery_enabled Application.compile_env(
                              :robot_sim,
                              :multinode_initial_recovery_enabled,
                              true
                            )
  @remote_ack_timeout_ms Application.compile_env(
                           :robot_sim,
                           :multinode_remote_ack_timeout_ms,
                           90_000
                         )
  @remote_max_restarts Application.compile_env(
                         :robot_sim,
                         :multinode_remote_max_restarts,
                         1
                       )
  @initial_connection_observation_ms 8_000
  @net_kernel_stop_poll_ms 50
  @net_kernel_stop_poll_attempts 40
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
    trace_connection(:role_started, role: @role)

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

  @doc "Return the Controller peer descriptors in physical polling order."
  @spec controller_peers(1..247, 1..247) :: [
          %{role: :drive | :sensors, unit_id: 1..247, node: node()}
        ]
  def controller_peers(drive_unit_id \\ 1, sensors_unit_id \\ 2) do
    [
      %{role: :drive, unit_id: drive_unit_id, node: identity(:drive)},
      %{role: :sensors, unit_id: sensors_unit_id, node: identity(:sensors)}
    ]
  end

  @doc "Return the Controller's logical stream targets in polling order."
  @spec targets(1..247, 1..247) :: [{:drive | :sensors, 1..247}]
  def targets(drive_unit_id \\ 1, sensors_unit_id \\ 2) do
    Enum.map(controller_peers(drive_unit_id, sensors_unit_id), fn peer ->
      {peer.role, peer.unit_id}
    end)
  end

  @doc "Return the alternating application-probe order for one soak cycle."
  @spec soak_targets(pos_integer()) :: [:drive | :sensors]
  def soak_targets(cycle) when is_integer(cycle) and cycle > 0 do
    if rem(cycle, 2) == 1, do: [:drive, :sensors], else: [:sensors, :drive]
  end

  @doc "Return the response-fault budget for a replacement distribution adapter."
  @spec restart_fault_drop_responses(non_neg_integer(), boolean()) :: non_neg_integer()
  def restart_fault_drop_responses(drop_responses, true)
      when is_integer(drop_responses) and drop_responses >= 0,
      do: drop_responses

  def restart_fault_drop_responses(drop_responses, false)
      when is_integer(drop_responses) and drop_responses >= 0,
      do: 0

  @doc "Classify a traffic start request against the most recently accepted run."
  @spec classify_traffic_start(pos_integer() | nil, pos_integer()) :: :new | :duplicate
  def classify_traffic_start(run_id, run_id) when is_integer(run_id) and run_id > 0,
    do: :duplicate

  def classify_traffic_start(previous_run_id, run_id)
      when (is_integer(previous_run_id) or previous_run_id == nil) and is_integer(run_id) and
             run_id > 0,
      do: :new

  @doc "Classify a remote readiness announcement against the Controller state."
  @spec classify_readiness(
          map(),
          :drive | :sensors,
          node(),
          pid(),
          pos_integer(),
          pos_integer()
        ) ::
          :new | :duplicate | :unexpected
  def classify_readiness(remotes, role, remote_node, pid, boot_id, connection_id)
      when role in [:drive, :sensors] and is_pid(pid) and is_integer(boot_id) and boot_id > 0 and
             is_integer(connection_id) and connection_id > 0 do
    cond do
      remote_node != identity(role) -> :unexpected
      true -> classify_known_remote(Map.get(remotes, role), pid, boot_id, connection_id)
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
          pos_integer(),
          pos_integer()
        ) ::
          {:retry | :continue | :duplicate | :unexpected, map()}
  def soak_readiness_transition(
        remotes,
        awaited_role,
        role,
        remote_node,
        pid,
        boot_id,
        connection_id
      )
      when awaited_role in [:drive, :sensors] and role in [:drive, :sensors] and is_pid(pid) and
             is_integer(boot_id) and boot_id > 0 and is_integer(connection_id) and
             connection_id > 0 do
    case classify_readiness(remotes, role, remote_node, pid, boot_id, connection_id) do
      :new ->
        action = if role == awaited_role, do: :retry, else: :continue

        {action,
         Map.put(remotes, role, %{
           pid: pid,
           boot_id: boot_id,
           connection_id: connection_id
         })}

      :duplicate ->
        {:duplicate, remotes}

      :unexpected ->
        {:unexpected, remotes}
    end
  end

  defp classify_known_remote(
         %{pid: pid, boot_id: boot_id, connection_id: connection_id},
         pid,
         boot_id,
         connection_id
       ),
       do: :duplicate

  defp classify_known_remote(_remote, _pid, _boot_id, _connection_id), do: :new

  defp expire_remote(remotes, role, now_ms, lease_ms) do
    case Map.get(remotes, role) do
      %{last_seen_ms: last_seen_ms} when now_ms - last_seen_ms > lease_ms ->
        {[role], Map.put(remotes, role, nil)}

      _remote ->
        {[], remotes}
    end
  end

  defp start_controller do
    case PollScheduler.start_link(delay_ms: @poll_ms) do
      {:ok, scheduler} -> start_controller_client(scheduler)
      {:error, reason} -> halt("poll scheduler start failed", reason)
    end
  end

  defp start_controller_client(scheduler) do
    case Client.start_link(
           transport: :rtu,
           serial: @serial,
           gap: @gap_ms,
           timeout: @timeout_ms
         ) do
      {:ok, client} ->
        start_controller_budget(client, scheduler)

      {:error, reason} ->
        GenServer.stop(scheduler)
        halt("shared Modbus client start failed", reason)
    end
  end

  defp start_controller_budget(client, scheduler) do
    case QueueBudget.start_link(
           max_queued_bytes: @global_max_queued_bytes,
           max_queued_chunks: @global_max_queued_chunks
         ) do
      {:ok, budget} ->
        IO.puts(
          "modbus_robot_multinode: global queue budget bytes=#{@global_max_queued_bytes} chunks=#{@global_max_queued_chunks}"
        )

        start_controller_adapters(client, scheduler, budget)

      {:error, reason} ->
        Client.stop(client)
        GenServer.stop(scheduler)
        halt("global queue budget start failed", reason)
    end
  end

  defp start_controller_adapters(client, scheduler, budget) do
    peers = controller_peers(@drive_unit_id, @sensors_unit_id)

    case open_client_adapters(client, scheduler, budget, peers, []) do
      {:ok, adapters} ->
        Enum.each(adapters, fn adapter ->
          :ok = PollScheduler.register(scheduler, adapter.uart)
        end)

        :ok = PollScheduler.start(scheduler)
        start_controller_distribution(client, scheduler, budget, adapters)

      {:error, role, reason} ->
        GenServer.stop(budget)
        Client.stop(client)
        GenServer.stop(scheduler)
        halt("#{role} adapter start failed", reason)
    end
  end

  defp start_controller_distribution(client, scheduler, budget, adapters) do
    IO.puts("modbus_robot_multinode: waiting for #{length(adapters)} FC-100 peers")
    trace_connection(:carrier_wait_started, role: :controller, peers: length(adapters))

    wait_for_peers(Enum.map(adapters, fn adapter -> {adapter.role, adapter.uart} end))

    ports =
      Enum.map(adapters, fn adapter ->
        uart_options(:client, adapter.unit_id, existing: adapter.uart)
      end)

    trace_connection(:distribution_start_started, role: :controller)

    case :net_kernel.start(identity(:controller), dist_options(ports)) do
      {:ok, _pid} ->
        :ok = :net_kernel.set_cookie(@cookie)
        true = :erlang.register(@controller_name, self())
        trace_connection(:distribution_start_succeeded, role: :controller)

        IO.puts(
          "modbus_robot_multinode: Controller distribution ready with #{length(adapters)} streams"
        )

        await_remotes(
          Enum.reduce(adapters, %{}, fn adapter, remotes ->
            Map.put(remotes, adapter.role, nil)
          end),
          Enum.reduce(adapters, %{}, fn adapter, uart_by_role ->
            Map.put(uart_by_role, adapter.role, adapter.uart)
          end)
        )

      other ->
        trace_connection(:distribution_start_failed, role: :controller, reason: other)
        close_client_adapters(adapters)
        GenServer.stop(budget)
        Client.stop(client)
        GenServer.stop(scheduler)
        halt("Controller net_kernel start failed", other)
    end
  end

  defp start_remote(role) do
    trace_connection(:distribution_start_started, role: role)

    case start_remote_kernel(role) do
      :ok ->
        trace_connection(:distribution_start_succeeded, role: role)
        start_role_process(role)
        true = :erlang.register(@remote_name, self())
        IO.puts("modbus_robot_multinode: #{role} distribution ready unit=#{@unit_id}")
        boot_id = Session.new_id()
        connection_id = Session.new_id()

        health =
          RemoteHealth.new(connection_id, monotonic_ms(),
            enabled: @remote_health_enabled,
            ack_timeout_ms: @remote_ack_timeout_ms,
            max_restarts: @remote_max_restarts
          )

        schedule_remote_memory_metrics(role)
        begin_remote_connection(role, boot_id, connection_id, health, nil)

      {:error, reason} ->
        trace_connection(:distribution_start_failed, role: role, reason: reason)
        halt("#{role} net_kernel start failed", reason)
    end
  end

  defp start_remote_kernel(role, fault_drop_responses \\ @fault_drop_responses) do
    ports = [uart_options(:server, @unit_id, fault_drop_responses: fault_drop_responses)]

    case :net_kernel.start(identity(role), dist_options(ports)) do
      {:ok, _pid} ->
        :ok = :net_kernel.set_cookie(@cookie)
        :ok

      other ->
        {:error, other}
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

  defp begin_remote_connection(role, boot_id, connection_id, health, traffic_run_id) do
    trace_connection(:readiness_wait_started,
      role: role,
      boot_id: boot_id,
      connection_id: connection_id
    )

    announce(role, boot_id, connection_id)
    schedule_remote_announce(connection_id, 2_000)
    schedule_initial_connection_observation(connection_id)
    remote_loop(role, boot_id, connection_id, health, traffic_run_id)
  end

  defp remote_loop(role, boot_id, connection_id, health, traffic_run_id) do
    receive do
      {:multinode_ack, ^role, ^connection_id} ->
        IO.puts("modbus_robot_multinode: #{role} acknowledged by Controller")

        trace_connection(:readiness_acknowledged,
          role: role,
          boot_id: boot_id,
          connection_id: connection_id
        )

        next_health = acknowledge_remote_health(role, health, connection_id)
        connected_remote_loop(role, boot_id, connection_id, next_health, traffic_run_id)

      {:multinode_ack, ^role, _stale_connection_id} ->
        remote_loop(role, boot_id, connection_id, health, traffic_run_id)

      {:remote_announce, ^connection_id} ->
        announce(role, boot_id, connection_id)
        schedule_remote_announce(connection_id, 2_000)
        remote_loop(role, boot_id, connection_id, health, traffic_run_id)

      {:remote_announce, _stale_connection_id} ->
        remote_loop(role, boot_id, connection_id, health, traffic_run_id)

      {:initial_connection_observation_timeout, ^connection_id} ->
        trace_connection(:initial_connection_timeout,
          role: role,
          boot_id: boot_id,
          connection_id: connection_id,
          wait_ms: @initial_connection_observation_ms
        )

        handle_initial_connection_timeout(
          role,
          boot_id,
          connection_id,
          health,
          traffic_run_id
        )

      {:initial_connection_observation_timeout, _stale_connection_id} ->
        remote_loop(role, boot_id, connection_id, health, traffic_run_id)

      {:multinode_probe, from, reference} when is_pid(from) ->
        send(from, {:multinode_probe_reply, reference, role, node()})
        remote_loop(role, boot_id, connection_id, health, traffic_run_id)

      {:multinode_soak, from, reference, id, payload}
      when is_pid(from) and is_binary(payload) ->
        reply_to_soak(from, reference, id, role, payload)
        remote_loop(role, boot_id, connection_id, health, traffic_run_id)

      {:robot_traffic_start, starter, collector, run_id, samples, interval_ms, payload_bytes,
       ack_timeout_ms, ack_retries}
      when is_pid(starter) and is_pid(collector) ->
        next_run_id =
          accept_traffic_start(
            starter,
            collector,
            role,
            run_id,
            samples,
            interval_ms,
            payload_bytes,
            ack_timeout_ms,
            ack_retries,
            traffic_run_id
          )

        remote_loop(role, boot_id, connection_id, health, next_run_id)

      {:robot_traffic_ack_timeout, _producer, ^role, run_id, context} ->
        handle_remote_ack_timeout(
          role,
          boot_id,
          connection_id,
          health,
          traffic_run_id,
          run_id,
          context
        )

      {:log_periodic_memory, ^role} ->
        log_remote_memory(role)
        schedule_remote_memory_metrics(role)
        remote_loop(role, boot_id, connection_id, health, traffic_run_id)
    end
  end

  defp connected_remote_loop(role, boot_id, connection_id, health, traffic_run_id) do
    receive do
      {:multinode_ack, ^role, ^connection_id} ->
        next_health = acknowledge_remote_health(role, health, connection_id)
        connected_remote_loop(role, boot_id, connection_id, next_health, traffic_run_id)

      {:multinode_ack, ^role, _stale_connection_id} ->
        connected_remote_loop(role, boot_id, connection_id, health, traffic_run_id)

      {:remote_announce, ^connection_id} ->
        handle_remote_health_tick(role, boot_id, connection_id, health, traffic_run_id)

      {:remote_announce, _stale_connection_id} ->
        connected_remote_loop(role, boot_id, connection_id, health, traffic_run_id)

      {:initial_connection_observation_timeout, _connection_id} ->
        connected_remote_loop(role, boot_id, connection_id, health, traffic_run_id)

      {:multinode_probe, from, reference} when is_pid(from) ->
        send(from, {:multinode_probe_reply, reference, role, node()})
        connected_remote_loop(role, boot_id, connection_id, health, traffic_run_id)

      {:multinode_soak, from, reference, id, payload}
      when is_pid(from) and is_binary(payload) ->
        reply_to_soak(from, reference, id, role, payload)
        connected_remote_loop(role, boot_id, connection_id, health, traffic_run_id)

      {:robot_traffic_start, starter, collector, run_id, samples, interval_ms, payload_bytes,
       ack_timeout_ms, ack_retries}
      when is_pid(starter) and is_pid(collector) ->
        next_run_id =
          accept_traffic_start(
            starter,
            collector,
            role,
            run_id,
            samples,
            interval_ms,
            payload_bytes,
            ack_timeout_ms,
            ack_retries,
            traffic_run_id
          )

        connected_remote_loop(role, boot_id, connection_id, health, next_run_id)

      {:robot_traffic_ack_timeout, _producer, ^role, run_id, context} ->
        handle_remote_ack_timeout(
          role,
          boot_id,
          connection_id,
          health,
          traffic_run_id,
          run_id,
          context
        )

      {:log_periodic_memory, ^role} ->
        log_remote_memory(role)
        schedule_remote_memory_metrics(role)
        connected_remote_loop(role, boot_id, connection_id, health, traffic_run_id)
    end
  end

  defp accept_traffic_start(
         starter,
         collector,
         role,
         run_id,
         samples,
         interval_ms,
         payload_bytes,
         ack_timeout_ms,
         ack_retries,
         previous_run_id
       ) do
    case classify_traffic_start(previous_run_id, run_id) do
      :new ->
        ConcurrentTraffic.start_producer(
          collector,
          role,
          run_id,
          samples,
          interval_ms,
          payload_bytes,
          ack_timeout_ms,
          ack_retries,
          self()
        )

        send(starter, {:robot_traffic_start_ack, role, run_id})
        run_id

      :duplicate ->
        send(starter, {:robot_traffic_start_ack, role, run_id})
        previous_run_id
    end
  end

  defp acknowledge_remote_health(role, health, connection_id) do
    now_ms = monotonic_ms()
    next_health = RemoteHealth.acknowledge(health, connection_id, now_ms)

    if @remote_health_trace and health.connection_ack_count > 0 do
      IO.puts(
        "modbus_robot_health: ACK role=#{role} connection=#{connection_id} " <>
          "gap_ms=#{max(now_ms - health.last_ack_ms, 0)} " <>
          "max_gap_ms=#{next_health.max_ack_gap_ms} count=#{next_health.ack_count}"
      )
    end

    next_health
  end

  defp handle_remote_health_tick(role, boot_id, connection_id, health, traffic_run_id) do
    announce(role, boot_id, connection_id)
    now_ms = monotonic_ms()

    case RemoteHealth.evaluate(health, now_ms) do
      {:restart, next_health} ->
        elapsed_ms = now_ms - health.last_ack_ms

        restart_remote_distribution(
          role,
          boot_id,
          connection_id,
          next_health,
          traffic_run_id,
          {:readiness_ack_timeout, elapsed_ms}
        )

      {:exhausted, next_health} ->
        log_restart_budget_exhausted(role, connection_id, next_health, :remote_health)

        continue_remote_health(role, boot_id, connection_id, next_health, traffic_run_id)

      {_status, next_health} ->
        continue_remote_health(role, boot_id, connection_id, next_health, traffic_run_id)
    end
  end

  defp handle_initial_connection_timeout(
         role,
         boot_id,
         connection_id,
         health,
         traffic_run_id
       ) do
    if @initial_recovery_enabled do
      case RemoteHealth.request_restart(health, monotonic_ms()) do
        {:restart, next_health} ->
          restart_remote_distribution(
            role,
            boot_id,
            connection_id,
            next_health,
            traffic_run_id,
            {:initial_connection_timeout, @initial_connection_observation_ms}
          )

        {:exhausted, next_health} ->
          log_restart_budget_exhausted(role, connection_id, next_health, :initial_connection)
          remote_loop(role, boot_id, connection_id, next_health, traffic_run_id)

        {:waiting, next_health} ->
          remote_loop(role, boot_id, connection_id, next_health, traffic_run_id)
      end
    else
      remote_loop(role, boot_id, connection_id, health, traffic_run_id)
    end
  end

  defp continue_remote_health(role, boot_id, connection_id, health, traffic_run_id) do
    schedule_remote_announce(connection_id, @announce_ms)
    connected_remote_loop(role, boot_id, connection_id, health, traffic_run_id)
  end

  defp log_restart_budget_exhausted(role, connection_id, health, source) do
    IO.puts(
      "modbus_robot_multinode: restart budget exhausted " <>
        "role=#{role} connection=#{connection_id} restarts=#{health.restarts} source=#{source}"
    )

    trace_connection(:restart_budget_exhausted,
      role: role,
      connection_id: connection_id,
      restarts: health.restarts,
      source: source
    )
  end

  defp handle_remote_ack_timeout(
         role,
         boot_id,
         connection_id,
         health,
         traffic_run_id,
         run_id,
         context
       ) do
    if @restart_on_traffic_ack_timeout do
      restart_remote_distribution(
        role,
        boot_id,
        connection_id,
        health,
        traffic_run_id,
        {:traffic_ack_timeout, run_id, context}
      )
    else
      connected_remote_loop(role, boot_id, connection_id, health, traffic_run_id)
    end
  end

  defp restart_remote_distribution(
         role,
         boot_id,
         previous_connection_id,
         health,
         traffic_run_id,
         reason
       ) do
    IO.puts(
      "modbus_robot_multinode: restarting distribution role=#{role} " <>
        "connection=#{previous_connection_id} reason=#{inspect(reason)}"
    )

    trace_connection(:restart_started,
      role: role,
      connection_id: previous_connection_id,
      reason: reason
    )

    case restart_remote_kernel(role) do
      :ok ->
        next_connection_id = Session.new_id()
        next_health = RemoteHealth.reconnected(health, next_connection_id, monotonic_ms())

        IO.puts(
          "modbus_robot_multinode: distribution restarted role=#{role} " <>
            "connection=#{next_connection_id}"
        )

        trace_connection(:restart_succeeded,
          role: role,
          previous_connection_id: previous_connection_id,
          connection_id: next_connection_id
        )

        begin_remote_connection(role, boot_id, next_connection_id, next_health, traffic_run_id)

      {:error, restart_reason} ->
        trace_connection(:restart_failed, role: role, reason: restart_reason)
        halt("#{role} distribution restart failed", restart_reason)
    end
  end

  defp restart_remote_kernel(role) do
    fault_drop_responses =
      restart_fault_drop_responses(@fault_drop_responses, @fault_rearm_on_restart)

    case :net_kernel.stop() do
      :ok ->
        await_remote_kernel_stop(role, @net_kernel_stop_poll_attempts, fault_drop_responses)

      other ->
        {:error, {:net_kernel_stop_failed, other}}
    end
  end

  defp await_remote_kernel_stop(role, attempts_left, fault_drop_responses)
       when attempts_left > 0 do
    case Process.whereis(:net_kernel) do
      nil ->
        start_remote_kernel(role, fault_drop_responses)

      _pid ->
        receive do
        after
          @net_kernel_stop_poll_ms ->
            await_remote_kernel_stop(role, attempts_left - 1, fault_drop_responses)
        end
    end
  end

  defp await_remote_kernel_stop(_role, 0, _fault_drop_responses) do
    {:error, {:net_kernel_stop_timeout, Process.whereis(:net_kernel)}}
  end

  defp announce(role, boot_id, connection_id) do
    send(
      {@controller_name, identity(:controller)},
      {:multinode_ready, role, node(), self(), boot_id, connection_id}
    )
  end

  defp schedule_remote_announce(connection_id, delay_ms) do
    Process.send_after(self(), {:remote_announce, connection_id}, delay_ms)
    :ok
  end

  if @connection_trace or @initial_recovery_enabled do
    defp schedule_initial_connection_observation(connection_id) do
      Process.send_after(
        self(),
        {:initial_connection_observation_timeout, connection_id},
        @initial_connection_observation_ms
      )

      :ok
    end
  else
    defp schedule_initial_connection_observation(_connection_id), do: :ok
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
         :ok <- probe_remote(:sensors, identity(:sensors)) do
      remotes = %{drive: drive, sensors: sensors}
      mission = start_sensor_mission()
      schedule_controller_metrics()
      controller_loop(remotes, adapters, mission, nil, Endurance.new(@traffic_runs))
    else
      {:error, reason} -> halt("remote initialization failed", reason)
    end
  end

  defp await_remotes(remotes, adapters) do
    receive do
      {:multinode_ready, role, remote_node, pid, boot_id, connection_id}
      when role in [:drive, :sensors] and is_pid(pid) and is_integer(boot_id) and boot_id > 0 and
             is_integer(connection_id) and connection_id > 0 ->
        case classify_readiness(remotes, role, remote_node, pid, boot_id, connection_id) do
          :new ->
            send(pid, {:multinode_ack, role, connection_id})
            IO.puts("modbus_robot_multinode: connected role=#{role} node=#{inspect(remote_node)}")

            trace_connection(:remote_connected,
              role: role,
              boot_id: boot_id,
              connection_id: connection_id
            )

            await_remotes(
              track_remote(remotes, role, pid, boot_id, connection_id),
              adapters
            )

          :duplicate ->
            send(pid, {:multinode_ack, role, connection_id})

            await_remotes(
              track_remote(remotes, role, pid, boot_id, connection_id),
              adapters
            )

          :unexpected ->
            log_unexpected_node(role, remote_node)
            await_remotes(remotes, adapters)
        end
    after
      @probe_timeout_ms -> halt("timed out waiting for remote nodes", remotes)
    end
  end

  defp controller_loop(remotes, adapters, mission, recovery, endurance) do
    receive do
      {MissionWorker, ^mission, {:ok, result}} when is_pid(mission) ->
        IO.puts("modbus_robot_multinode: sensor mission complete state=#{inspect(result.rover)}")
        IO.puts("modbus_robot_multinode: complete Drive and Sensors remote messaging")
        remotes = run_soak_if_enabled(remotes)
        schedule_traffic_if_enabled(@traffic_start_delay_ms)
        controller_loop(remotes, adapters, nil, recovery, endurance)

      {MissionWorker, ^mission, {:error, reason}} when is_pid(mission) ->
        IO.puts("modbus_robot_multinode: sensor mission stopped reason=#{inspect(reason)}")

        recovery = start_recovery_if_indeterminate(reason)
        controller_loop(remotes, adapters, nil, recovery, endurance)

      {RecoveryWorker, ^recovery, {:ok, snapshot}} when is_pid(recovery) ->
        IO.puts(
          "modbus_robot_multinode: recovery snapshot " <>
            "boot_id=#{snapshot.boot_id} state=#{inspect(snapshot.rover)} " <>
            "mission_error=#{inspect(snapshot.mission_error)}"
        )

        controller_loop(remotes, adapters, mission, nil, endurance)

      {RecoveryWorker, ^recovery, {:error, reason}} when is_pid(recovery) ->
        IO.puts("modbus_robot_multinode: recovery snapshot failed reason=#{inspect(reason)}")
        controller_loop(remotes, adapters, mission, nil, endurance)

      {:robot_traffic_complete, run_id, summary} ->
        log_adapter_metrics("after", adapters)
        schedule_settled_metrics(run_id)

        IO.puts(
          "modbus_robot_multinode: concurrent traffic report run=#{run_id} " <>
            "outcome=#{summary.outcome}"
        )

        case Endurance.complete(endurance, summary.outcome) do
          {:ok, run_index, :continue, next_endurance} ->
            IO.puts(
              "modbus_robot_endurance: run=#{run_index}/#{@traffic_runs} " <>
                "outcome=#{summary.outcome} idle_ms=#{@traffic_idle_ms}"
            )

            schedule_traffic_if_enabled(@traffic_idle_ms)
            controller_loop(remotes, adapters, mission, recovery, next_endurance)

          {:ok, run_index, :complete, next_endurance} ->
            IO.puts(
              "modbus_robot_endurance: complete run=#{run_index}/#{@traffic_runs} " <>
                "summary=#{inspect(Endurance.summary(next_endurance))}"
            )

            controller_loop(remotes, adapters, mission, recovery, next_endurance)

          {:error, reason} ->
            IO.puts(
              "modbus_robot_endurance: unexpected completion run=#{run_id} " <>
                "reason=#{inspect(reason)}"
            )

            controller_loop(remotes, adapters, mission, recovery, endurance)
        end

      :start_multinode_traffic ->
        case Endurance.start_next(endurance) do
          {:ok, run_index, next_endurance} ->
            IO.puts("modbus_robot_endurance: starting run=#{run_index}/#{@traffic_runs}")
            start_traffic_if_enabled(adapters)
            controller_loop(remotes, adapters, mission, recovery, next_endurance)

          {:error, reason} ->
            IO.puts("modbus_robot_endurance: start skipped reason=#{inspect(reason)}")
            controller_loop(remotes, adapters, mission, recovery, endurance)
        end

      {:robot_traffic_metrics_settled, run_id} ->
        log_adapter_metrics("settled", adapters)
        IO.puts("modbus_robot_metrics: settled run=#{run_id}")
        controller_loop(remotes, adapters, mission, recovery, endurance)

      :log_periodic_metrics ->
        log_adapter_metrics("periodic", adapters)
        schedule_controller_metrics()
        controller_loop(remotes, adapters, mission, recovery, endurance)

      {:multinode_ready, role, remote_node, pid, boot_id, connection_id}
      when role in [:drive, :sensors] and is_pid(pid) and is_integer(boot_id) and boot_id > 0 and
             is_integer(connection_id) and connection_id > 0 ->
        case classify_readiness(remotes, role, remote_node, pid, boot_id, connection_id) do
          :duplicate ->
            send(pid, {:multinode_ack, role, connection_id})

            controller_loop(
              track_remote(remotes, role, pid, boot_id, connection_id),
              adapters,
              mission,
              recovery,
              endurance
            )

          :new ->
            send(pid, {:multinode_ack, role, connection_id})

            next_remotes = track_remote(remotes, role, pid, boot_id, connection_id)

            IO.puts(
              "modbus_robot_multinode: reconnected role=#{role} node=#{inspect(remote_node)}"
            )

            trace_connection(:remote_reconnected,
              role: role,
              boot_id: boot_id,
              connection_id: connection_id
            )

            verify_recovery(role, next_remotes)
            controller_loop(next_remotes, adapters, mission, recovery, endurance)

          :unexpected ->
            log_unexpected_node(role, remote_node)
            controller_loop(remotes, adapters, mission, recovery, endurance)
        end
    after
      @health_check_ms ->
        {expired_roles, next_remotes} =
          expire_stale_remotes(remotes, monotonic_ms(), @lease_ms)

        log_expired_roles(expired_roles)
        controller_loop(next_remotes, adapters, mission, recovery, endurance)
    end
  end

  defp verify_recovery(restarted_role, remotes) do
    peer_role = if restarted_role == :drive, do: :sensors, else: :drive

    with :ok <- probe_remote(restarted_role, identity(restarted_role)),
         :ok <- probe_remote(peer_role, identity(peer_role)) do
      IO.puts(
        "modbus_robot_multinode: recovery complete restarted=#{restarted_role} peer=#{peer_role}"
      )

      trace_connection(:recovery_verified, role: restarted_role)
      trace_maintained_peer(peer_role, Map.get(remotes, peer_role))
    else
      {:error, reason} ->
        IO.puts("modbus_robot_multinode: recovery probe failed #{inspect(reason)}")
        trace_connection(:recovery_verification_failed, role: restarted_role, reason: reason)
    end
  end

  defp log_unexpected_node(role, remote_node) do
    IO.puts(
      "modbus_robot_multinode: ignored unexpected node role=#{role} node=#{inspect(remote_node)}"
    )
  end

  defp track_remote(remotes, role, pid, boot_id, connection_id) do
    Map.put(remotes, role, %{
      pid: pid,
      boot_id: boot_id,
      connection_id: connection_id,
      last_seen_ms: monotonic_ms()
    })
  end

  defp monotonic_ms, do: :erlang.monotonic_time(:millisecond)

  defp trace_connection(event, fields) do
    ConnectionTrace.emit(@connection_trace, event, monotonic_ms(), fields)
  end

  defp trace_maintained_peer(role, %{boot_id: boot_id, connection_id: connection_id}) do
    trace_connection(:peer_maintained,
      role: role,
      boot_id: boot_id,
      connection_id: connection_id
    )
  end

  defp trace_maintained_peer(role, _remote) do
    trace_connection(:recovery_verification_failed,
      role: role,
      reason: :peer_identity_missing
    )
  end

  defp log_expired_roles([]), do: :ok

  defp log_expired_roles([role | rest]) do
    IO.puts("modbus_robot_multinode: readiness lease expired role=#{role}")
    trace_connection(:stale_detected, role: role)
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

  defp start_sensor_mission do
    MissionWorker.start(
      self(),
      {@sensors_name, identity(:sensors)},
      {@drive_name, identity(:drive)},
      steps: @sensor_mission_steps,
      first_request_id: Session.new_id(),
      timeout_ms: @probe_timeout_ms,
      max_retries: @mission_retries,
      trace: true
    )
  end

  defp start_recovery_if_indeterminate(reason) do
    if indeterminate_command?(reason) do
      RecoveryWorker.start(
        self(),
        {@drive_name, identity(:drive)},
        reason,
        request_id: Session.new_id(),
        timeout_ms: @probe_timeout_ms,
        max_retries: @mission_retries,
        trace: true
      )
    else
      nil
    end
  end

  defp indeterminate_command?({:indeterminate_command, _request_id, _old_boot, _new_boot}),
    do: true

  defp indeterminate_command?({:sensor_mission_failed, _step, reason}),
    do: indeterminate_command?(reason)

  defp indeterminate_command?(_reason), do: false

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

  defp schedule_traffic_if_enabled(delay_ms) do
    if @traffic_samples > 0 do
      Process.send_after(self(), :start_multinode_traffic, delay_ms)

      if delay_ms > 0 do
        IO.puts(
          "modbus_robot_multinode: concurrent traffic scheduled " <>
            "delay_ms=#{delay_ms}"
        )
      end
    end

    :ok
  end

  if @metrics_interval_ms > 0 do
    defp schedule_controller_metrics do
      Process.send_after(self(), :log_periodic_metrics, @metrics_interval_ms)
      :ok
    end

    defp schedule_remote_memory_metrics(role) do
      Process.send_after(self(), {:log_periodic_memory, role}, @metrics_interval_ms)
      :ok
    end
  else
    defp schedule_controller_metrics, do: :ok
    defp schedule_remote_memory_metrics(_role), do: :ok
  end

  defp log_remote_memory(role) do
    IO.puts(
      "modbus_robot_memory: role=#{role} " <>
        MemorySnapshot.format(MemorySnapshot.capture())
    )
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
    log_resource_metric(phase, role, snapshot)
  end

  defp log_resource_metric(phase, role, %{memory: memory, global_queue_budget: global} = snapshot)
       when memory != nil and global != nil do
    IO.puts(
      "modbus_robot_resource: phase=#{phase} peer=#{role} " <>
        "queued_bytes=#{snapshot.queued_bytes} outstanding=#{snapshot.outstanding} " <>
        "max_queued_bytes=#{snapshot.max_queued_bytes} max_outstanding=#{snapshot.max_outstanding} " <>
        "free_heap_bytes=#{memory.free_heap_bytes} " <>
        "minimum_free_heap_bytes=#{memory.minimum_free_heap_bytes} " <>
        "global_queued_bytes=#{global.queued_bytes} global_queued_chunks=#{global.queued_chunks} " <>
        "global_max_queued_bytes=#{global.max_queued_bytes_observed} " <>
        "global_max_queued_chunks=#{global.max_queued_chunks_observed} " <>
        "global_rejected=#{global.rejected} " <>
        "transaction_failures=#{snapshot.transactions.failures}"
    )
  end

  defp log_resource_metric(_phase, _role, _snapshot), do: :ok

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

      {:multinode_ready, ready_role, ready_node, pid, boot_id, connection_id}
      when ready_role in [:drive, :sensors] and is_pid(pid) and is_integer(boot_id) and
             boot_id > 0 and is_integer(connection_id) and connection_id > 0 ->
        case soak_readiness_transition(
               remotes,
               role,
               ready_role,
               ready_node,
               pid,
               boot_id,
               connection_id
             ) do
          {:duplicate, next_remotes} ->
            send(pid, {:multinode_ack, ready_role, connection_id})

            next_remotes =
              track_remote(next_remotes, ready_role, pid, boot_id, connection_id)

            await_soak_reply(role, remote_node, id, payload, reference, next_remotes, deadline)

          {action, next_remotes} when action in [:retry, :continue] ->
            send(pid, {:multinode_ack, ready_role, connection_id})

            next_remotes =
              track_remote(next_remotes, ready_role, pid, boot_id, connection_id)

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

  defp open_client_adapter(client, unit_id, scheduler, budget) do
    case ModbusUART.open(
           uart_options(:client, unit_id,
             client: client,
             poll_scheduler: scheduler,
             queue_budget: budget
           )
         ) do
      pid when is_pid(pid) -> {:ok, pid}
      {:error, _reason} = error -> error
    end
  end

  defp open_client_adapters(_client, _scheduler, _budget, [], adapters),
    do: {:ok, Enum.reverse(adapters)}

  defp open_client_adapters(client, scheduler, budget, [peer | rest], adapters) do
    case open_client_adapter(client, peer.unit_id, scheduler, budget) do
      {:ok, uart} ->
        adapter = Map.put(peer, :uart, uart)
        open_client_adapters(client, scheduler, budget, rest, [adapter | adapters])

      {:error, reason} ->
        close_client_adapters(adapters)
        {:error, peer.role, reason}
    end
  end

  defp close_client_adapters(adapters) do
    Enum.each(adapters, fn adapter -> ModbusUART.close(adapter.uart) end)
  end

  defp wait_for_peers([]), do: :ok

  defp wait_for_peers([{role, uart} | rest]) do
    if ModbusUART.peer_ready?(uart) do
      IO.puts("modbus_robot_multinode: FC-100 peer ready role=#{role}")
      trace_connection(:carrier_peer_ready, role: role)
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

  defp uart_options(role, unit_id, extra) do
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
        fault_drop_responses: @fault_drop_responses,
        fault_min_payload_bytes: @fault_min_payload_bytes,
        fault_after_ms: @fault_after_ms,
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
