defmodule RobotSim.Rover do
  @moduledoc """
  Pure, deterministic virtual rover for the first robot experiment.

  Coordinates are millimetres and headings are multiples of 90 degrees.
  Heading `0` points along `+X`; positive headings rotate clockwise, so
  heading `90` points along `+Y`.

  No physical hardware or distribution transport is used here.
  """

  @type turn_direction :: :left | :right
  @type command :: {:forward, pos_integer()} | {:turn, turn_direction(), pos_integer()} | :status
  @type t :: %__MODULE__{
          x_mm: integer(),
          y_mm: integer(),
          heading_deg: 0 | 90 | 180 | 270
        }

  defstruct x_mm: 0, y_mm: 0, heading_deg: 0

  @doc "Return a rover at the mission origin, facing along `+X`."
  @spec new() :: t()
  def new, do: %__MODULE__{}

  @doc "Execute a command and return the updated rover state."
  @spec execute(t(), command()) ::
          {:ok, t()} | {:error, :invalid_command}
  def execute(%__MODULE__{} = rover, :status), do: {:ok, rover}

  def execute(%__MODULE__{} = rover, {:turn, direction, degrees})
      when direction in [:left, :right] and is_integer(degrees) and degrees > 0 and
             rem(degrees, 90) == 0 do
    delta = if direction == :right, do: degrees, else: -degrees
    {:ok, %{rover | heading_deg: normalize_heading(rover.heading_deg + delta)}}
  end

  def execute(%__MODULE__{} = rover, {:forward, distance_mm})
      when is_integer(distance_mm) and distance_mm > 0 do
    next =
      case rover.heading_deg do
        0 -> %{rover | x_mm: rover.x_mm + distance_mm}
        90 -> %{rover | y_mm: rover.y_mm + distance_mm}
        180 -> %{rover | x_mm: rover.x_mm - distance_mm}
        270 -> %{rover | y_mm: rover.y_mm - distance_mm}
      end

    {:ok, next}
  end

  def execute(%__MODULE__{}, _command), do: {:error, :invalid_command}

  defp normalize_heading(heading_deg) do
    case rem(heading_deg, 360) do
      negative when negative < 0 -> negative + 360
      normalized -> normalized
    end
  end
end
