defmodule RobotSim.MissionWorkerTest do
  use ExUnit.Case

  alias RobotSim.{Drive, MissionWorker, Rover, Sensors}

  test "reports mission completion to its owner from a separate process" do
    sensors = start_supervised!(Sensors)
    drive = start_supervised!(Drive)

    worker =
      MissionWorker.start(self(), sensors, drive,
        steps: 3,
        first_request_id: 100,
        timeout_ms: 100,
        max_retries: 0
      )

    refute worker == self()

    assert_receive {MissionWorker, ^worker,
                    {:ok, %{rover: %Rover{x_mm: 200, y_mm: 0, heading_deg: 90}}}}
  end

  test "leaves unrelated owner messages available while a mission is in flight" do
    drive = start_supervised!(Drive)
    worker = MissionWorker.start(self(), self(), drive, timeout_ms: 50, max_retries: 0)

    send(self(), :health_check)
    assert_receive :health_check

    assert_receive {MissionWorker, ^worker,
                    {:error, {:sensor_mission_failed, 1, :sensor_timeout}}}
  end
end
