defmodule RobotSim.MissionWorker do
  @moduledoc """
  Runs a sensor-driven mission outside the Controller health loop.

  The owner remains available to acknowledge readiness heartbeats and expire
  leases while the worker waits for remote sensor, relay, and drive replies.
  """

  alias RobotSim.SensorMission

  @type destination :: GenServer.server()
  @type result :: {:ok, SensorMission.result()} | {:error, term()}
  @type message :: {__MODULE__, pid(), result()}

  @doc "Start one mission and report its result to the owner process."
  @spec start(pid(), destination(), destination(), keyword()) :: pid()
  def start(owner, sensors, drive, options \\ [])
      when is_pid(owner) and is_list(options) do
    spawn(fn ->
      result = SensorMission.run(sensors, drive, options)
      send(owner, {__MODULE__, self(), result})
    end)
  end
end
