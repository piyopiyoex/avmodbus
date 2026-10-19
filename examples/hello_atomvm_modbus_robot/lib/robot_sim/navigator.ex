defmodule RobotSim.Navigator do
  @moduledoc """
  Pure navigation decisions derived from virtual sensor samples.

  Low battery takes priority over movement. With sufficient battery, a nearby
  obstacle causes a right turn; otherwise the rover advances.
  """

  alias RobotSim.Sensors

  @obstacle_distance_mm 400
  @low_battery_percent 20
  @forward_distance_mm 100

  @type reason :: :clear_path | :obstacle | :low_battery
  @type decision :: %{reason: reason(), command: RobotSim.Rover.command()}

  @doc "Return the deterministic navigation decision for one sensor sample."
  @spec decide(Sensors.sample()) :: {:ok, decision()} | {:error, :invalid_sample}
  def decide(sample) do
    if Sensors.valid_sample?(sample) do
      {:ok, decision_for_valid_sample(sample)}
    else
      {:error, :invalid_sample}
    end
  end

  defp decision_for_valid_sample(%{battery_percent: battery_percent})
       when battery_percent <= @low_battery_percent,
       do: %{reason: :low_battery, command: :status}

  defp decision_for_valid_sample(%{distance_mm: distance_mm})
       when distance_mm <= @obstacle_distance_mm,
       do: %{reason: :obstacle, command: {:turn, :right, 90}}

  defp decision_for_valid_sample(_sample),
    do: %{reason: :clear_path, command: {:forward, @forward_distance_mm}}
end
