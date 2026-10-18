defmodule RobotSim.Distributed do
  @moduledoc """
  AtomVM entry point for the two-node virtual robot experiment.

  It reuses the experimental Modbus virtual UART from `disterl_probe` and keeps
  the robot application protocol in this project.
  """

  @compile {:no_warn_undefined, :net_kernel}

  alias RobotSim.{Controller, Drive}

  @drive_name :modbus_robot_drive
  @role Application.compile_env(:robot_sim, :role, :controller)
  @transport_role Application.compile_env(:robot_sim, :transport_role, :client)
  @serial Application.compile_env(:robot_sim, :serial, [])
  @unit_id Application.compile_env(:robot_sim, :unit_id, 1)
  @timeout_ms Application.compile_env(:robot_sim, :timeout_ms, 500)
  @bulk_timeout_ms Application.compile_env(:robot_sim, :bulk_timeout_ms, 2_000)
  @chunk_payload_bytes Application.compile_env(:robot_sim, :chunk_payload_bytes, 96)
  @max_queued_bytes Application.compile_env(:robot_sim, :max_queued_bytes, 8_192)
  @max_queued_chunks Application.compile_env(:robot_sim, :max_queued_chunks, 256)
  @poll_ms Application.compile_env(:robot_sim, :poll_ms, 20)
  @trace_transactions Application.compile_env(:robot_sim, :trace_transactions, false)
  @trace_queue Application.compile_env(:robot_sim, :trace_queue, false)
  @wait_for_peer Application.compile_env(:robot_sim, :wait_for_peer, true)
  @cookie Application.compile_env(:robot_sim, :cookie, "AtomVM")
  @mission_timeout_ms Application.compile_env(:robot_sim, :mission_timeout_ms, 60_000)
  @mission_retries Application.compile_env(:robot_sim, :mission_retries, 1)
  @mission_start_delay_ms Application.compile_env(
                            :robot_sim,
                            :mission_start_delay_ms,
                            2_000
                          )
  @first_request_id Application.compile_env(:robot_sim, :first_request_id, 1)

  @doc "Start the configured controller or drive node."
  @spec start() :: no_return()
  def start do
    identity = identity(@role)
    uart = prepare_uart()

    case :net_kernel.start(identity.node, dist_options(uart)) do
      {:ok, _pid} ->
        :ok = :net_kernel.set_cookie(@cookie)
        log_started(identity)
        start_role(identity)

      other ->
        if uart != nil, do: DisterlProbe.ModbusUART.close(uart)
        halt("net_kernel start failed", other)
    end
  end

  @doc false
  def identity(:controller) do
    %{role: :controller, node: :"controller@modbus.local", peer: :"drive@modbus.local"}
  end

  def identity(:drive) do
    %{role: :drive, node: :"drive@modbus.local", peer: :"controller@modbus.local"}
  end

  defp start_role(identity) do
    case identity.role do
      :drive ->
        {:ok, _drive} = Drive.start_link(name: @drive_name)
        IO.puts("modbus_robot: drive process registered as #{inspect(@drive_name)}")
        Process.sleep(:infinity)

      :controller ->
        Process.sleep(@mission_start_delay_ms)

        options = [
          first_request_id: @first_request_id,
          timeout_ms: @mission_timeout_ms,
          max_retries: @mission_retries
        ]

        IO.puts("modbus_robot: starting reference mission on #{inspect(identity.peer)}")

        case Controller.demo({@drive_name, identity.peer}, options) do
          {:ok, rover} ->
            IO.puts(
              "modbus_robot: mission complete x_mm=#{rover.x_mm} y_mm=#{rover.y_mm} heading_deg=#{rover.heading_deg}"
            )

          {:error, reason} ->
            IO.puts("modbus_robot: mission failed #{inspect(reason)}")
        end

        Process.sleep(:infinity)
    end
  end

  defp prepare_uart do
    if @wait_for_peer and @transport_role == :client do
      case DisterlProbe.ModbusUART.open(uart_options()) do
        pid when is_pid(pid) ->
          IO.puts("modbus_robot: waiting for FC-100 peer before starting net_kernel")
          wait_for_peer(pid)

        {:error, reason} ->
          halt("peer readiness failed", reason)
      end
    else
      nil
    end
  end

  defp wait_for_peer(pid) do
    if DisterlProbe.ModbusUART.peer_ready?(pid) do
      IO.puts("modbus_robot: FC-100 peer ready; starting net_kernel")
      pid
    else
      Process.sleep(max(@poll_ms, 1))
      wait_for_peer(pid)
    end
  end

  defp dist_options(uart) do
    %{
      name_domain: :longnames,
      proto_dist: :serial_dist,
      avm_dist_opts: %{
        uart_opts: uart_options(uart),
        uart_module: DisterlProbe.ModbusUART
      }
    }
  end

  defp uart_options(existing \\ nil) do
    options = [
      role: @transport_role,
      serial: @serial,
      unit_id: @unit_id,
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

    if existing == nil, do: options, else: [{:existing, existing} | options]
  end

  defp log_started(identity) do
    IO.puts("modbus_robot: node #{inspect(identity.node)} role=#{identity.role}")
    IO.puts("modbus_robot: peer #{inspect(identity.peer)}")
    IO.puts("modbus_robot: virtual UART over FC-100 ready")
  end

  defp halt(message, reason) do
    IO.puts("modbus_robot: #{message} #{inspect(reason)}")
    Process.sleep(:infinity)
  end
end
