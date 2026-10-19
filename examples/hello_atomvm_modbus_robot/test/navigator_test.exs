defmodule RobotSim.NavigatorTest do
  use ExUnit.Case, async: true

  alias RobotSim.Navigator

  test "advances when the path is clear" do
    assert Navigator.decide(%{sequence: 1, distance_mm: 401, battery_percent: 100}) ==
             {:ok, %{reason: :clear_path, command: {:forward, 100}}}
  end

  test "turns right at the obstacle threshold" do
    assert Navigator.decide(%{sequence: 1, distance_mm: 400, battery_percent: 100}) ==
             {:ok, %{reason: :obstacle, command: {:turn, :right, 90}}}
  end

  test "holds position when battery is low even if the path is clear" do
    assert Navigator.decide(%{sequence: 1, distance_mm: 500, battery_percent: 20}) ==
             {:ok, %{reason: :low_battery, command: :status}}
  end

  test "rejects malformed samples" do
    assert Navigator.decide(%{sequence: 1, distance_mm: -1, battery_percent: 100}) ==
             {:error, :invalid_sample}
  end
end
