defmodule RobotSim do
  @moduledoc """
  Local robot simulation used to validate movement semantics before
  introducing genuine distributed Erlang over Modbus RTU.
  """

  alias RobotSim.Rover

  @mission [{:forward, 100}, {:turn, :right, 90}, {:forward, 50}]
  @expected_demo_state %Rover{x_mm: 100, y_mm: 50, heading_deg: 90}

  @doc "Return the deterministic reference mission."
  @spec mission() :: [Rover.command()]
  def mission, do: @mission

  @doc "Return the expected final state of the reference mission."
  @spec expected_demo_state() :: Rover.t()
  def expected_demo_state, do: @expected_demo_state

  @doc "Run the reference mission, returning its final state."
  @spec demo() :: {:ok, Rover.t()} | {:error, :invalid_command}
  def demo, do: run(@mission)

  @doc "Run commands against a fresh rover."
  @spec run([Rover.command()]) :: {:ok, Rover.t()} | {:error, :invalid_command}
  def run(commands), do: run(commands, Rover.new())

  @doc "Run commands against the supplied rover state."
  @spec run([Rover.command()], Rover.t()) :: {:ok, Rover.t()} | {:error, :invalid_command}
  def run(commands, %Rover{} = initial_rover) when is_list(commands) do
    run_commands(commands, initial_rover)
  end

  defp run_commands([], rover), do: {:ok, rover}

  defp run_commands([command | rest], rover) do
    case Rover.execute(rover, command) do
      {:ok, next} -> run_commands(rest, next)
      {:error, _reason} = error -> error
    end
  end
end
