defmodule RobotSim.RecoveryWorker do
  @moduledoc """
  Reads a non-mutating Drive snapshot after an indeterminate mission outcome.

  The snapshot is guarded by the newly observed Drive boot ID. It is evidence
  for an operator or higher-level application, not an automatic mission resume.
  """

  alias DisterlProbe.Session
  alias RobotSim.Controller

  @type destination :: GenServer.server()
  @type snapshot :: %{
          boot_id: pos_integer(),
          rover: RobotSim.Rover.t(),
          mission_error: term()
        }
  @type result :: {:ok, snapshot()} | {:error, term()}
  @type message :: {__MODULE__, pid(), result()}

  @doc "Start one guarded Drive snapshot and report its result to the owner process."
  @spec start(pid(), destination(), term(), keyword()) :: pid()
  def start(owner, drive, mission_error, options \\ [])
      when is_pid(owner) and is_list(options) do
    spawn(fn ->
      request_id = Keyword.get(options, :request_id, Session.new_id())

      result =
        with {:ok, boot_id} <- Controller.drive_identity(drive, options),
             guarded_options = Keyword.put(options, :expected_boot_id, boot_id),
             {:ok, rover} <- Controller.command(drive, request_id, :status, guarded_options) do
          {:ok, %{boot_id: boot_id, rover: rover, mission_error: mission_error}}
        end

      send(owner, {__MODULE__, self(), result})
    end)
  end
end
