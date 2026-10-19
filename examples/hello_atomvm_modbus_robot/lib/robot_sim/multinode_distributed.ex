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
  alias DisterlProbe.ModbusUART
  alias RobotSim.Drive

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

  @controller_name :modbus_robot_controller
  @remote_name :modbus_robot_remote
  @drive_name :modbus_robot_drive

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
        await_remotes(%{drive: nil, sensors: nil})

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
        remote_loop(role)

      other ->
        halt("#{role} net_kernel start failed", other)
    end
  end

  defp start_role_process(:drive) do
    {:ok, _drive} = Drive.start_link(name: @drive_name)
    IO.puts("modbus_robot_multinode: Drive process registered as #{inspect(@drive_name)}")
  end

  defp start_role_process(:sensors), do: :ok

  defp remote_loop(role) do
    announce(role)

    receive do
      {:multinode_ack, ^role} ->
        IO.puts("modbus_robot_multinode: #{role} acknowledged by Controller")
        connected_remote_loop(role)

      {:multinode_probe, from, reference} when is_pid(from) ->
        send(from, {:multinode_probe_reply, reference, role, node()})
        remote_loop(role)
    after
      2_000 -> remote_loop(role)
    end
  end

  defp connected_remote_loop(role) do
    receive do
      {:multinode_ack, ^role} ->
        connected_remote_loop(role)

      {:multinode_probe, from, reference} when is_pid(from) ->
        send(from, {:multinode_probe_reply, reference, role, node()})
        connected_remote_loop(role)
    end
  end

  defp announce(role) do
    send(
      {@controller_name, identity(:controller)},
      {:multinode_ready, role, node(), self()}
    )
  end

  defp await_remotes(%{drive: drive, sensors: sensors})
       when is_pid(drive) and is_pid(sensors) do
    IO.puts("modbus_robot_multinode: both remote nodes connected")

    with :ok <- probe_remote(:drive, identity(:drive)),
         :ok <- probe_remote(:sensors, identity(:sensors)) do
      IO.puts("modbus_robot_multinode: complete Drive and Sensors remote messaging")
      Process.sleep(:infinity)
    else
      {:error, reason} -> halt("remote probe failed", reason)
    end
  end

  defp await_remotes(remotes) do
    receive do
      {:multinode_ready, role, remote_node, pid}
      when role in [:drive, :sensors] and is_pid(pid) ->
        expected_node = identity(role)

        if remote_node == expected_node do
          send(pid, {:multinode_ack, role})
          IO.puts("modbus_robot_multinode: connected role=#{role} node=#{inspect(remote_node)}")
          await_remotes(Map.put(remotes, role, pid))
        else
          IO.puts(
            "modbus_robot_multinode: ignored unexpected node role=#{role} node=#{inspect(remote_node)}"
          )

          await_remotes(remotes)
        end
    after
      @probe_timeout_ms -> halt("timed out waiting for remote nodes", remotes)
    end
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
