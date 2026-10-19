defmodule RobotSim.SensorsRelayTest do
  use ExUnit.Case

  alias RobotSim.{Drive, Relay, Sensors}

  test "virtual samples are deterministic and remain in their documented ranges" do
    assert Sensors.build_sample(1) ==
             %{sequence: 1, distance_mm: 500, battery_percent: 100}

    assert Sensors.build_sample(6) ==
             %{sequence: 6, distance_mm: 500, battery_percent: 95}

    assert Sensors.valid_sample?(Sensors.build_sample(10))
    refute Sensors.valid_sample?(%{sequence: 0, distance_mm: 500, battery_percent: 100})
    refute Sensors.valid_sample?(%{sequence: 1, distance_mm: -1, battery_percent: 100})
    refute Sensors.valid_sample?(%{sequence: 1, distance_mm: 500, battery_percent: 101})
  end

  test "Controller relay forwards a Sensors sample to Drive" do
    sensors = start_supervised!(Sensors)
    drive = start_supervised!(Drive)

    assert {:ok,
            %{
              sensors_node: sensors_node,
              drive_node: drive_node,
              sample: %{sequence: 1, distance_mm: 500, battery_percent: 100} = sample
            }} = Relay.run(sensors, drive)

    assert sensors_node == node()
    assert drive_node == node()
    assert Drive.last_sensor_sample(drive) == %{source_node: node(), sample: sample}
  end

  test "Drive rejects an invalid relayed sample without replacing the last valid sample" do
    drive = start_supervised!(Drive)
    reference = make_ref()

    send(
      drive,
      {:relayed_sensor_sample, self(), reference, :"sensors@modbus.local",
       %{sequence: 1, distance_mm: -1, battery_percent: 100}}
    )

    assert_receive {:sensor_sample_rejected, ^reference, _drive_node, :invalid_sample}
    assert Drive.last_sensor_sample(drive) == nil
  end

  test "Sensors increments the sequence for each request" do
    sensors = start_supervised!(Sensors)

    assert %{sequence: 1} = Sensors.sample(sensors)
    assert %{sequence: 2} = Sensors.sample(sensors)
  end
end
