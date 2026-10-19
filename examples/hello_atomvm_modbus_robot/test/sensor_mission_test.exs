defmodule RobotSim.SensorMissionTest do
  use ExUnit.Case

  alias RobotSim.{Drive, Rover, SensorMission, Sensors}

  test "uses clear-path and obstacle samples to change the rover mission" do
    sensors = start_supervised!(Sensors)
    drive = start_supervised!(Drive)

    assert {:ok,
            %{
              steps: [
                %{step: 1, reason: :clear_path, command: {:forward, 100}},
                %{step: 2, reason: :clear_path, command: {:forward, 100}},
                %{step: 3, reason: :obstacle, command: {:turn, :right, 90}}
              ],
              rover: %Rover{x_mm: 200, y_mm: 0, heading_deg: 90}
            }} = SensorMission.run(sensors, drive)

    assert %{sample: %{sequence: 3, distance_mm: 400}} = Drive.last_sensor_sample(drive)
  end

  test "rejects invalid mission bounds before sending messages" do
    assert SensorMission.run(self(), self(), steps: 0) == {:error, :invalid_steps}

    assert SensorMission.run(self(), self(), first_request_id: -1) ==
             {:error, :invalid_first_request_id}
  end
end
