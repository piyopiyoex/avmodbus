defmodule RobotSim.ApplicationRecoveryTest do
  use ExUnit.Case

  alias RobotSim.{ApplicationRecovery, Drive, Rover, Sensors}

  test "classifies a sensor timeout as an explicit mission abort" do
    assert ApplicationRecovery.classify_failure({:sensor_mission_failed, 2, :sensor_timeout}) ==
             %{
               outcome: :aborted,
               action: :stop,
               step: 2,
               reason: :sensor_timeout
             }
  end

  test "classifies a Drive boot change as indeterminate" do
    reason = {:indeterminate_command, 101, 10, 11}

    assert ApplicationRecovery.classify_failure({:sensor_mission_failed, 3, reason}) == %{
             outcome: :indeterminate,
             action: :snapshot,
             step: 3,
             reason: reason
           }
  end

  test "fetches a fresh sample and guarded Drive status without moving" do
    sensors = start_supervised!(Sensors)
    drive = start_supervised!({Drive, boot_id: 456, initial: %Rover{x_mm: 25}})

    assert {:ok,
            %{
              boot_id: 456,
              rover: %Rover{x_mm: 25},
              sample: %{sequence: 1},
              sensors_node: sensors_node,
              drive_node: drive_node
            }} =
             ApplicationRecovery.verify(sensors, drive,
               request_id: 900,
               timeout_ms: 100,
               max_retries: 0
             )

    assert sensors_node == node()
    assert drive_node == node()
    assert %Rover{x_mm: 25} = Drive.state(drive)
    assert %{sample: %{sequence: 1}} = Drive.last_sensor_sample(drive)
  end

  test "reports a bounded sensor timeout from a separate process" do
    drive = start_supervised!(Drive)

    worker =
      ApplicationRecovery.start(self(), self(), drive,
        request_id: 901,
        timeout_ms: 20,
        max_retries: 0
      )

    assert_receive {ApplicationRecovery, ^worker, {:error, :sensor_timeout}}, 100
    assert %Rover{} = Drive.state(drive)
  end
end
