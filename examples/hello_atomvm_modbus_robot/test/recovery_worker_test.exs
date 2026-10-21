defmodule RobotSim.RecoveryWorkerTest do
  use ExUnit.Case

  alias RobotSim.{Drive, Protocol, RecoveryWorker, Rover}

  test "reports a guarded snapshot from the current Drive boot" do
    drive = start_supervised!({Drive, boot_id: 456, initial: %Rover{x_mm: 25}})
    mission_error = {:indeterminate_command, 10, 123, 456}

    worker =
      RecoveryWorker.start(self(), drive, mission_error,
        request_id: 11,
        timeout_ms: 100,
        max_retries: 0
      )

    assert_receive {RecoveryWorker, ^worker,
                    {:ok,
                     %{
                       boot_id: 456,
                       rover: %Rover{x_mm: 25},
                       mission_error: ^mission_error
                     }}}

    assert %Rover{x_mm: 25} = Drive.state(drive)
  end

  test "rejects a snapshot if Drive changes boots after identity" do
    drive = spawn(fn -> serve_boot_change(123, 456) end)

    worker =
      RecoveryWorker.start(self(), drive, :mission_error,
        request_id: 11,
        timeout_ms: 100,
        max_retries: 0
      )

    assert_receive {RecoveryWorker, ^worker, {:error, {:indeterminate_command, 11, 123, 456}}}
  end

  test "leaves unrelated owner messages available while the snapshot waits" do
    worker =
      RecoveryWorker.start(self(), self(), :mission_error,
        request_id: 11,
        timeout_ms: 50,
        max_retries: 0
      )

    send(self(), :health_check)
    assert_receive :health_check
    assert_receive {RecoveryWorker, ^worker, {:error, :drive_identity_timeout}}
  end

  defp serve_boot_change(old_boot_id, new_boot_id) do
    receive do
      {:drive_identity_request, reply_to, reference} ->
        send(reply_to, Protocol.identity_reply(reference, old_boot_id))
    end

    receive do
      {:robot_guarded_command, reply_to, request_id, ^old_boot_id, :status} ->
        result = {:error, {:drive_boot_changed, new_boot_id}}
        send(reply_to, Protocol.reply(request_id, result))
    end
  end
end
