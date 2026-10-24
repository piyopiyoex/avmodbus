defmodule RobotSim.Protocol do
  @moduledoc """
  Application-level messages exchanged by the mission controller and drive process.

  The protocol is independent of Modbus and Erlang distribution. A remote caller can
  send the same terms to a registered process once the two AtomVM nodes are connected.
  Guarded commands bind execution to one volatile Drive boot identity.
  """

  alias RobotSim.Rover

  @type request_id :: non_neg_integer()
  @type boot_id :: pos_integer()
  @type result ::
          {:ok, Rover.t()}
          | {:error,
             :invalid_command
             | :request_id_conflict
             | {:drive_boot_changed, boot_id()}}
  @type request ::
          {:robot_command, pid(), request_id(), Rover.command()}
          | {:robot_guarded_command, pid(), request_id(), boot_id(), Rover.command()}
  @type reply :: {:robot_reply, request_id(), result()}
  @type identity_request :: {:drive_identity_request, pid(), reference()}
  @type identity_reply :: {:drive_identity_reply, reference(), boot_id()}

  @doc "Build a command request that identifies where the reply should be sent."
  @spec request(pid(), request_id(), Rover.command()) :: request()
  def request(reply_to, request_id, command)
      when is_pid(reply_to) and is_integer(request_id) and request_id >= 0 do
    {:robot_command, reply_to, request_id, command}
  end

  @doc "Build a command request that is valid only for one Drive boot."
  @spec guarded_request(pid(), request_id(), boot_id(), Rover.command()) :: request()
  def guarded_request(reply_to, request_id, expected_boot_id, command)
      when is_pid(reply_to) and is_integer(request_id) and request_id >= 0 and
             is_integer(expected_boot_id) and expected_boot_id > 0 do
    {:robot_guarded_command, reply_to, request_id, expected_boot_id, command}
  end

  @doc "Build a reply correlated with a command request."
  @spec reply(request_id(), result()) :: reply()
  def reply(request_id, result) when is_integer(request_id) and request_id >= 0 do
    {:robot_reply, request_id, result}
  end

  @doc "Build a request for the current volatile Drive boot identity."
  @spec identity_request(pid(), reference()) :: identity_request()
  def identity_request(reply_to, reference) when is_pid(reply_to) and is_reference(reference) do
    {:drive_identity_request, reply_to, reference}
  end

  @doc "Build a Drive boot identity reply."
  @spec identity_reply(reference(), boot_id()) :: identity_reply()
  def identity_reply(reference, boot_id)
      when is_reference(reference) and is_integer(boot_id) and boot_id > 0 do
    {:drive_identity_reply, reference, boot_id}
  end
end
