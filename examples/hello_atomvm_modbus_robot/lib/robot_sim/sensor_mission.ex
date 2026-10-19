defmodule RobotSim.SensorMission do
  @moduledoc """
  Sequential Controller mission driven by remote virtual sensor samples.

  Every step relays one Sensors sample to Drive, makes a pure navigation
  decision, and sends the resulting command with request-ID deduplication.
  """

  alias RobotSim.{Controller, Navigator, Relay, Rover}

  @default_steps 3
  @default_first_request_id 1_000

  @type destination :: GenServer.server()
  @type completed_step :: %{
          step: pos_integer(),
          sample: RobotSim.Sensors.sample(),
          reason: Navigator.reason(),
          command: Rover.command(),
          rover: Rover.t(),
          sensors_node: node(),
          drive_node: node()
        }
  @type result :: %{steps: [completed_step()], rover: Rover.t()}

  @doc "Run a bounded sensor-driven mission and return its decisions and final rover state."
  @spec run(destination(), destination(), keyword()) :: {:ok, result()} | {:error, term()}
  def run(sensors, drive, options \\ []) do
    steps = Keyword.get(options, :steps, @default_steps)
    first_request_id = Keyword.get(options, :first_request_id, @default_first_request_id)

    validate_and_run(sensors, drive, steps, first_request_id, options)
  end

  defp validate_and_run(_sensors, _drive, steps, _first_request_id, _options)
       when not is_integer(steps) or steps < 1,
       do: {:error, :invalid_steps}

  defp validate_and_run(_sensors, _drive, _steps, first_request_id, _options)
       when not is_integer(first_request_id) or first_request_id < 0,
       do: {:error, :invalid_first_request_id}

  defp validate_and_run(sensors, drive, steps, first_request_id, options) do
    with {:ok, completed, status_request_id} <-
           run_steps(sensors, drive, steps, 1, first_request_id, options, []),
         {:ok, rover} <- Controller.command(drive, status_request_id, :status, options) do
      {:ok, %{steps: :lists.reverse(completed), rover: rover}}
    end
  end

  defp run_steps(_sensors, _drive, 0, _step, request_id, _options, completed),
    do: {:ok, completed, request_id}

  defp run_steps(sensors, drive, remaining, step, request_id, options, completed)
       when remaining > 0 do
    timeout_ms = Keyword.get(options, :timeout_ms, 5_000)

    with {:ok, relay} <- Relay.run(sensors, drive, timeout_ms: timeout_ms),
         {:ok, decision} <- Navigator.decide(relay.sample),
         {:ok, rover} <- Controller.command(drive, request_id, decision.command, options) do
      completed_step = %{
        step: step,
        sample: relay.sample,
        reason: decision.reason,
        command: decision.command,
        rover: rover,
        sensors_node: relay.sensors_node,
        drive_node: relay.drive_node
      }

      trace_step(Keyword.get(options, :trace, false), completed_step)

      run_steps(
        sensors,
        drive,
        remaining - 1,
        step + 1,
        request_id + 1,
        options,
        [completed_step | completed]
      )
    else
      {:error, reason} -> {:error, {:sensor_mission_failed, step, reason}}
    end
  end

  defp trace_step(false, _step), do: :ok

  defp trace_step(true, step) do
    IO.puts(
      "modbus_robot_multinode: sensor mission step=#{step.step} " <>
        "sample=#{inspect(step.sample)} reason=#{step.reason} " <>
        "command=#{inspect(step.command)} state=#{inspect(step.rover)}"
    )
  end
end
