defmodule RobotSim do
  @moduledoc """
  Local robot simulation used to validate movement semantics before
  introducing genuine distributed Erlang over Modbus RTU.
  """

  alias RobotSim.Rover

  @mission [{:forward, 100}, {:turn, :right, 90}, {:forward, 50}]

  @doc "Return the deterministic reference mission."
  @spec mission() :: [Rover.command()]
  def mission, do: @mission

  @doc "Run the reference mission, returning its final state."
  @spec demo() :: {:ok, Rover.t()} | {:error, :invalid_command}
  def demo, do: run(@mission)

  @doc "Run commands against a fresh rover."
  @spec run([Rover.command()]) :: {:ok, Rover.t()} | {:error, :invalid_command}
  def run(commands), do: run(commands, Rover.new())

  @doc "Run commands against the supplied rover state."
  @spec run([Rover.command()], Rover.t()) :: {:ok, Rover.t()} | {:error, :invalid_command}
  def run(commands, %Rover{} = initial_rover) when is_list(commands) do
    Enum.reduce_while(commands, {:ok, initial_rover}, fn command, {:ok, rover} ->
      case Rover.execute(rover, command) do
        {:ok, next} -> {:cont, {:ok, next}}
        {:error, _reason} = error -> {:halt, error}
      end
    end)
  end
end
