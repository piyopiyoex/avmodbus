defmodule RobotSim.RoverTest do
  use ExUnit.Case, async: true

  alias RobotSim.Rover

  test "a new rover starts at the origin facing along positive X" do
    assert %Rover{x_mm: 0, y_mm: 0, heading_deg: 0} = Rover.new()
  end

  test "the reference mission moves along positive X, turns right, and moves along positive Y" do
    assert RobotSim.mission() == [
             {:forward, 100},
             {:turn, :right, 90},
             {:forward, 50}
           ]

    assert {:ok, %Rover{x_mm: 100, y_mm: 50, heading_deg: 90}} = RobotSim.demo()
  end

  test "turning left and right wraps headings" do
    assert {:ok, %Rover{heading_deg: 270}} =
             Rover.execute(Rover.new(), {:turn, :left, 90})

    assert {:ok, %Rover{heading_deg: 90}} =
             Rover.execute(Rover.new(), {:turn, :right, 450})
  end

  test "movement follows all cardinal headings" do
    assert {:ok, %Rover{x_mm: -10, y_mm: 0}} =
             Rover.execute(%Rover{heading_deg: 180}, {:forward, 10})

    assert {:ok, %Rover{x_mm: 0, y_mm: -10}} =
             Rover.execute(%Rover{heading_deg: 270}, {:forward, 10})
  end

  test "status does not change rover state" do
    rover = %Rover{x_mm: 10, heading_deg: 90}
    assert {:ok, ^rover} = Rover.execute(rover, :status)
  end

  test "invalid commands fail without updating state" do
    rover = Rover.new()
    assert {:error, :invalid_command} = Rover.execute(rover, {:forward, 0})
    assert {:error, :invalid_command} = Rover.execute(rover, {:forward, -10})
    assert {:error, :invalid_command} = Rover.execute(rover, {:turn, :right, 45})
    assert {:error, :invalid_command} = Rover.execute(rover, {:turn, :backward, 90})
    assert {:error, :invalid_command} = Rover.execute(rover, :stop)

    assert {:error, :invalid_command} =
             RobotSim.run([{:forward, 10}, {:turn, :right, 45}])
  end

  test "the same mission and initial state always produce the same result" do
    initial = %Rover{x_mm: -20, y_mm: 30, heading_deg: 180}
    mission = [{:forward, 40}, {:turn, :left, 90}, {:forward, 10}]

    assert RobotSim.run(mission, initial) == RobotSim.run(mission, initial)

    assert {:ok, %Rover{x_mm: -60, y_mm: 40, heading_deg: 90}} =
             RobotSim.run(mission, initial)
  end
end
