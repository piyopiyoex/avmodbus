defmodule RobotSim.SensorMissionTest do
  use ExUnit.Case

  alias RobotSim.{Drive, Protocol, Rover, SensorMission, Sensors}

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

    assert SensorMission.run(self(), self(), step_delay_ms: -1) ==
             {:error, :invalid_step_delay_ms}
  end

  test "applies a configured delay only between completed steps" do
    sensors = start_supervised!(Sensors)
    drive = start_supervised!(Drive)
    started_at = System.monotonic_time(:millisecond)

    assert {:ok, %{steps: [%{step: 1}, %{step: 2}]}} =
             SensorMission.run(sensors, drive, steps: 2, step_delay_ms: 20)

    assert System.monotonic_time(:millisecond) - started_at >= 20
  end

  test "stops with an indeterminate outcome instead of executing after a Drive reboot" do
    sensors = start_supervised!(Sensors)
    drive = spawn_link(fn -> rebooting_drive_proxy(100, Rover.new(), 0) end)

    assert SensorMission.run(sensors, drive,
             steps: 3,
             first_request_id: 100,
             timeout_ms: 100,
             max_retries: 0
           ) ==
             {:error, {:sensor_mission_failed, 2, {:indeterminate_command, 101, 100, 101}}}
  end

  defp rebooting_drive_proxy(boot_id, rover, completed_commands) do
    receive do
      {:drive_identity_request, reply_to, reference} ->
        send(reply_to, Protocol.identity_reply(reference, boot_id))
        rebooting_drive_proxy(boot_id, rover, completed_commands)

      {:relayed_sensor_sample, reply_to, reference, _source_node, sample} ->
        send(reply_to, {:sensor_sample_accepted, reference, node(), sample})
        rebooting_drive_proxy(boot_id, rover, completed_commands)

      {:robot_guarded_command, reply_to, request_id, ^boot_id, command}
      when completed_commands == 0 ->
        {:ok, next_rover} = Rover.execute(rover, command)
        send(reply_to, Protocol.reply(request_id, {:ok, next_rover}))
        rebooting_drive_proxy(boot_id + 1, next_rover, completed_commands + 1)

      {:robot_guarded_command, reply_to, request_id, _stale_boot_id, _command} ->
        send(reply_to, Protocol.reply(request_id, {:error, {:drive_boot_changed, boot_id}}))
        rebooting_drive_proxy(boot_id, rover, completed_commands)
    end
  end
end
