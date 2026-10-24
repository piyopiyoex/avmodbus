defmodule RobotSim.DriveTest do
  use ExUnit.Case

  alias RobotSim.{Controller, Drive, Protocol, Rover}

  test "the local controller completes the reference mission" do
    drive = start_supervised!(Drive)

    assert {:ok, %Rover{x_mm: 100, y_mm: 50, heading_deg: 90}} =
             Controller.demo(drive)
  end

  test "the controller rejects a reference mission with an unexpected final state" do
    drive = start_supervised!({Drive, initial: %Rover{x_mm: 10}})

    assert {:error, {:unexpected_final_state, %Rover{x_mm: 110, y_mm: 50, heading_deg: 90}}} =
             Controller.demo(drive)
  end

  test "repeating a request returns the cached result without moving twice" do
    drive = start_supervised!(Drive)

    assert {:ok, %Rover{x_mm: 100}} = Controller.command(drive, 1, {:forward, 100})
    assert {:ok, %Rover{x_mm: 100}} = Controller.command(drive, 1, {:forward, 100})
    assert %Rover{x_mm: 100} = Drive.state(drive)
  end

  test "reusing a request ID for another command is rejected" do
    drive = start_supervised!(Drive)

    assert {:ok, %Rover{x_mm: 100}} = Controller.command(drive, 1, {:forward, 100})

    assert {:error, :request_id_conflict} =
             Controller.command(drive, 1, {:turn, :right, 90})

    assert %Rover{x_mm: 100, y_mm: 0, heading_deg: 0} = Drive.state(drive)
  end

  test "reports a stable boot identity" do
    drive = start_supervised!({Drive, boot_id: 123})

    assert Controller.drive_identity(drive) == {:ok, 123}
    assert Controller.drive_identity(drive) == {:ok, 123}
  end

  test "executes a command guarded by the current boot identity" do
    drive = start_supervised!({Drive, boot_id: 123})

    assert {:ok, %Rover{x_mm: 100}} =
             Controller.command(drive, 10, {:forward, 100}, expected_boot_id: 123)

    assert %Rover{x_mm: 100} = Drive.state(drive)
  end

  test "rejects a stale boot identity without executing the command" do
    drive = start_supervised!({Drive, boot_id: 456})

    assert {:error, {:indeterminate_command, 10, 123, 456}} =
             Controller.command(drive, 10, {:forward, 100}, expected_boot_id: 123)

    assert Rover.new() == Drive.state(drive)
  end

  test "a request can execute again after its bounded cache entry is evicted" do
    drive = start_supervised!({Drive, max_completed: 1})

    assert {:ok, %Rover{x_mm: 10}} = Controller.command(drive, 1, {:forward, 10})
    assert {:ok, %Rover{x_mm: 10}} = Controller.command(drive, 2, :status)
    assert {:ok, %Rover{x_mm: 20}} = Controller.command(drive, 1, {:forward, 10})
  end

  test "a retry after a lost reply does not execute movement twice" do
    drive = start_supervised!(Drive)
    proxy = spawn_link(fn -> drop_first_reply_proxy(drive) end)

    assert {:ok, %Rover{x_mm: 100}} =
             Controller.command(proxy, 7, {:forward, 100}, timeout_ms: 20, max_retries: 1)

    assert %Rover{x_mm: 100} = Drive.state(drive)
  end

  test "Drive can inject one lost reply per request without executing a retry twice" do
    drive =
      start_supervised!({Drive, boot_id: 123, drop_first_reply_per_request: true})

    assert {:ok, %Rover{x_mm: 100}} =
             Controller.command(drive, 8, {:forward, 100},
               expected_boot_id: 123,
               timeout_ms: 20,
               max_retries: 1
             )

    assert %Rover{x_mm: 100} = Drive.state(drive)
  end

  test "the controller reports timeout after exhausting retries" do
    sink = spawn_link(fn -> discard_requests(2) end)

    assert {:error, :timeout} =
             Controller.command(sink, 1, :status, timeout_ms: 20, max_retries: 1)
  end

  test "unexpected calls and casts have AtomVM-safe failure reasons" do
    state = %{
      rover: Rover.new(),
      boot_id: 1,
      completed: [],
      max_completed: 32,
      trace: false,
      drop_first_reply_per_request: false,
      last_sensor_sample: nil
    }

    assert Drive.handle_call(:unexpected, :from, state) ==
             {:stop, {:bad_call, :unexpected}, state}

    assert Drive.handle_cast(:unexpected, state) ==
             {:stop, {:bad_cast, :unexpected}, state}
  end

  defp drop_first_reply_proxy(drive) do
    receive do
      {:robot_command, controller, request_id, command} ->
        send(drive, Protocol.request(self(), request_id, command))

        receive do
          {:robot_reply, ^request_id, _dropped_result} -> :ok
        end

        receive do
          {:robot_command, ^controller, ^request_id, ^command} ->
            send(drive, Protocol.request(self(), request_id, command))

            receive do
              {:robot_reply, ^request_id, result} ->
                send(controller, Protocol.reply(request_id, result))
            end
        end
    end
  end

  defp discard_requests(0), do: :ok

  defp discard_requests(remaining) do
    receive do
      _request -> discard_requests(remaining - 1)
    end
  end
end
