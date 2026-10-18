defmodule RobotSim.Protocol do
  @moduledoc """
  Application-level messages exchanged by the mission controller and drive process.

  The protocol is independent of Modbus and Erlang distribution. A remote caller can
  send the same terms to a registered process once the two AtomVM nodes are connected.
  """

  alias RobotSim.Rover

  @type request_id :: non_neg_integer()
  @type result :: {:ok, Rover.t()} | {:error, :invalid_command | :request_id_conflict}
  @type request :: {:robot_command, pid(), request_id(), Rover.command()}
  @type reply :: {:robot_reply, request_id(), result()}

  @doc "Build a command request that identifies where the reply should be sent."
  @spec request(pid(), request_id(), Rover.command()) :: request()
  def request(reply_to, request_id, command)
      when is_pid(reply_to) and is_integer(request_id) and request_id >= 0 do
    {:robot_command, reply_to, request_id, command}
  end

  @doc "Build a reply correlated with a command request."
  @spec reply(request_id(), result()) :: reply()
  def reply(request_id, result) when is_integer(request_id) and request_id >= 0 do
    {:robot_reply, request_id, result}
  end
end
