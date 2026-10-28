defmodule RobotSim.ApplicationRecovery do
  @moduledoc """
  Classifies a stopped mission and performs a non-moving post-recovery probe.

  The probe fetches a fresh Sensors sample, relays it to Drive, and reads Drive
  status with a boot-ID guard. It never resumes the stopped mission or sends a
  movement command.
  """

  alias DisterlProbe.Session
  alias RobotSim.{Controller, Protocol, Relay, Rover, Sensors}

  @type destination :: GenServer.server()
  @type classification :: %{
          outcome: :aborted | :indeterminate,
          action: :stop | :snapshot,
          step: nil | pos_integer(),
          reason: term()
        }
  @type snapshot :: %{
          boot_id: Protocol.boot_id(),
          rover: Rover.t(),
          sample: Sensors.sample(),
          sensors_node: node(),
          drive_node: node()
        }
  @type result :: {:ok, snapshot()} | {:error, term()}
  @type message :: {__MODULE__, pid(), result()}

  @doc "Classify a mission failure without deciding to resume it."
  @spec classify_failure(term()) :: classification()
  def classify_failure({:sensor_mission_failed, step, reason})
      when is_integer(step) and step > 0 do
    if indeterminate_command?(reason) do
      %{outcome: :indeterminate, action: :snapshot, step: step, reason: reason}
    else
      %{outcome: :aborted, action: :stop, step: step, reason: reason}
    end
  end

  def classify_failure(reason) do
    if indeterminate_command?(reason) do
      %{outcome: :indeterminate, action: :snapshot, step: nil, reason: reason}
    else
      %{outcome: :aborted, action: :stop, step: nil, reason: reason}
    end
  end

  @doc "Start one post-recovery probe and report its result to the owner process."
  @spec start(pid(), destination(), destination(), keyword()) :: pid()
  def start(owner, sensors, drive, options \\ [])
      when is_pid(owner) and is_list(options) do
    spawn(fn -> send(owner, {__MODULE__, self(), verify(sensors, drive, options)}) end)
  end

  @doc "Fetch and relay one fresh sample, then read guarded Drive status."
  @spec verify(destination(), destination(), keyword()) :: result()
  def verify(sensors, drive, options \\ []) do
    request_id = Keyword.get(options, :request_id, Session.new_id())
    timeout_ms = Keyword.get(options, :timeout_ms, 5_000)

    with {:ok, relay} <- Relay.run(sensors, drive, timeout_ms: timeout_ms),
         {:ok, boot_id} <- Controller.drive_identity(drive, timeout_ms: timeout_ms),
         guarded_options =
           options
           |> Keyword.put(:timeout_ms, timeout_ms)
           |> Keyword.put(:expected_boot_id, boot_id),
         {:ok, rover} <- Controller.command(drive, request_id, :status, guarded_options) do
      {:ok,
       %{
         boot_id: boot_id,
         rover: rover,
         sample: relay.sample,
         sensors_node: relay.sensors_node,
         drive_node: relay.drive_node
       }}
    end
  end

  defp indeterminate_command?({:indeterminate_command, _request_id, _old_boot, _new_boot}),
    do: true

  defp indeterminate_command?(_reason), do: false
end
