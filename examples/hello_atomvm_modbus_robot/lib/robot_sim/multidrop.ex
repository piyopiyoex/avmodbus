defmodule RobotSim.Multidrop do
  @moduledoc """
  Stage 2 standard Modbus RTU multidrop probe.

  The controller owns the shared UART and polls the Drive and Sensors servers
  sequentially. This mode intentionally does not start Erlang distribution.
  """

  alias AVModbus.{Client, Memory}
  alias AVModbus.Server.RTU, as: RTUServer

  @mode Application.compile_env(:robot_sim, :mode, :distributed)
  @role Application.compile_env(:robot_sim, :role, :controller)
  @serial Application.compile_env(:robot_sim, :serial, [])
  @unit_id Application.compile_env(:robot_sim, :unit_id, 1)
  @drive_unit_id Application.compile_env(:robot_sim, :drive_unit_id, 1)
  @sensors_unit_id Application.compile_env(:robot_sim, :sensors_unit_id, 2)
  @cycles Application.compile_env(:robot_sim, :multidrop_cycles, 3)
  @interval_ms Application.compile_env(:robot_sim, :multidrop_interval_ms, 1_000)
  @start_delay_ms Application.compile_env(:robot_sim, :multidrop_start_delay_ms, 2_000)
  @gap_ms Application.compile_env(:robot_sim, :multidrop_gap_ms, 20)
  @timeout_ms Application.compile_env(:robot_sim, :timeout_ms, 500)

  @doc "Start the configured Stage 2 role."
  @spec start() :: no_return()
  def start do
    case {@mode, @role} do
      {:multidrop, :controller} -> start_controller()
      {:multidrop, role} when role in [:drive, :sensors] -> start_server(role)
      other -> halt("invalid multidrop configuration", other)
    end
  end

  @doc "Return the Controller polling order."
  @spec targets(1..247, 1..247) :: [{:drive | :sensors, 1..247}]
  def targets(drive_unit_id \\ 1, sensors_unit_id \\ 2) do
    [{:drive, drive_unit_id}, {:sensors, sensors_unit_id}]
  end

  @doc "Return the two identity registers exposed by a server role."
  @spec identity_registers(:drive | :sensors, 1..247) :: [non_neg_integer()]
  def identity_registers(:drive, unit_id), do: [1, unit_id]
  def identity_registers(:sensors, unit_id), do: [2, unit_id]

  @doc "Validate one server's identity-register response."
  @spec validate_reply(:drive | :sensors, 1..247, term()) :: :ok | {:error, term()}
  def validate_reply(role, unit_id, {:ok, registers}) do
    expected = identity_registers(role, unit_id)

    if registers == expected do
      :ok
    else
      {:error, {:unexpected_registers, role, unit_id, expected, registers}}
    end
  end

  def validate_reply(role, unit_id, {:error, reason}),
    do: {:error, {:request_failed, role, unit_id, reason}}

  def validate_reply(role, unit_id, other),
    do: {:error, {:unexpected_reply, role, unit_id, other}}

  defp start_server(role) do
    with :ok <- validate_server_unit(role, @unit_id),
         {:ok, memory} <- Memory.start_link(),
         :ok <- Memory.put(memory, :holding_register, 0, identity_registers(role, @unit_id)),
         {:ok, _server} <-
           RTUServer.start_link({Memory, memory},
             units: [@unit_id],
             serial: @serial,
             gap: @gap_ms
           ) do
      IO.puts("modbus_robot_multidrop: role=#{role} unit=#{@unit_id} server ready")
      Process.sleep(:infinity)
    else
      {:error, reason} -> halt("server start failed", reason)
    end
  end

  defp start_controller do
    Process.sleep(@start_delay_ms)

    case Client.start_link(
           transport: :rtu,
           serial: @serial,
           gap: @gap_ms,
           timeout: @timeout_ms
         ) do
      {:ok, client} ->
        IO.puts(
          "modbus_robot_multidrop: controller started; polling units #{@drive_unit_id}, #{@sensors_unit_id}"
        )

        result = run_cycles(client, 1, empty_stats())
        IO.puts("modbus_robot_multidrop: complete result=#{inspect(result)}")
        Process.sleep(:infinity)

      {:error, reason} ->
        halt("client start failed", reason)
    end
  end

  defp run_cycles(_client, cycle, stats) when cycle > @cycles, do: outcome(stats)

  defp run_cycles(client, cycle, stats) do
    next_stats = poll_targets(client, cycle, targets(@drive_unit_id, @sensors_unit_id), stats)
    Process.sleep(@interval_ms)
    run_cycles(client, cycle + 1, next_stats)
  end

  defp poll_targets(_client, _cycle, [], stats), do: stats

  defp poll_targets(client, cycle, [{role, unit_id} | rest], stats) do
    started_at = :erlang.monotonic_time(:millisecond)

    reply =
      Client.read_holding_registers(client, unit_id, 0, 2,
        timeout: @timeout_ms,
        retries: 1,
        backoff: {100, 500}
      )

    elapsed_ms = :erlang.monotonic_time(:millisecond) - started_at

    IO.puts(
      "modbus_robot_multidrop: cycle=#{cycle} role=#{role} unit=#{unit_id} elapsed_ms=#{elapsed_ms} reply=#{inspect(reply)}"
    )

    validation = validate_reply(role, unit_id, reply)
    next_stats = record(stats, role, validation)
    poll_targets(client, cycle, rest, next_stats)
  end

  defp empty_stats do
    %{
      requests: 0,
      successes: 0,
      failures: 0,
      drive_successes: 0,
      drive_failures: 0,
      sensors_successes: 0,
      sensors_failures: 0
    }
  end

  defp record(stats, :drive, :ok) do
    %{
      stats
      | requests: stats.requests + 1,
        successes: stats.successes + 1,
        drive_successes: stats.drive_successes + 1
    }
  end

  defp record(stats, :sensors, :ok) do
    %{
      stats
      | requests: stats.requests + 1,
        successes: stats.successes + 1,
        sensors_successes: stats.sensors_successes + 1
    }
  end

  defp record(stats, :drive, {:error, _reason}) do
    %{
      stats
      | requests: stats.requests + 1,
        failures: stats.failures + 1,
        drive_failures: stats.drive_failures + 1
    }
  end

  defp record(stats, :sensors, {:error, _reason}) do
    %{
      stats
      | requests: stats.requests + 1,
        failures: stats.failures + 1,
        sensors_failures: stats.sensors_failures + 1
    }
  end

  defp outcome(%{failures: 0} = stats), do: {:ok, stats}
  defp outcome(stats), do: {:partial, stats}

  defp validate_server_unit(:drive, unit_id) when unit_id == @drive_unit_id, do: :ok
  defp validate_server_unit(:sensors, unit_id) when unit_id == @sensors_unit_id, do: :ok

  defp validate_server_unit(role, unit_id),
    do: {:error, {:unexpected_unit_id, role, unit_id}}

  defp halt(message, reason) do
    IO.puts("modbus_robot_multidrop: #{message} #{inspect(reason)}")
    Process.sleep(:infinity)
  end
end
