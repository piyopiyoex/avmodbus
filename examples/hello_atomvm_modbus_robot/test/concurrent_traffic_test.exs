defmodule RobotSim.ConcurrentTrafficTest do
  use ExUnit.Case, async: true

  alias RobotSim.ConcurrentTraffic

  test "two producers progress independently and the Controller collects both" do
    drive = fake_remote(:drive)
    sensors = fake_remote(:sensors)

    worker =
      ConcurrentTraffic.start(self(), [{:drive, drive}, {:sensors, sensors}],
        samples: 4,
        drive_interval_ms: 20,
        sensors_interval_ms: 5,
        payload_bytes: 12,
        timeout_ms: 2_000
      )

    assert is_pid(worker)
    assert_receive {:robot_traffic_complete, _run_id, summary}, 2_500
    assert summary.outcome == :complete
    assert summary.drive.received == 4
    assert summary.sensors.received == 4
    assert summary.drive.missing == 0
    assert summary.sensors.missing == 0
    assert summary.drive.finished
    assert summary.sensors.finished
    assert summary.drive.invalid == 0
    assert summary.sensors.invalid == 0
    assert summary.drive.duration_ms >= 0
    assert summary.sensors.duration_ms >= 0
    assert summary.fairness.delivery_ratio_gap_per_mille == 0
    assert summary.fairness.active_overlap_ms > 0
  end

  test "an unresponsive peer is reported as missing without hanging" do
    drive = fake_remote(:drive)

    sensors =
      spawn(fn ->
        receive do
          :stop -> :ok
        end
      end)

    ConcurrentTraffic.start(self(), [{:drive, drive}, {:sensors, sensors}],
      samples: 2,
      drive_interval_ms: 5,
      sensors_interval_ms: 5,
      payload_bytes: 0,
      timeout_ms: 100,
      ack_timeout_ms: 20,
      ack_retries: 1
    )

    assert_receive {:robot_traffic_complete, _run_id, summary}, 1_000
    assert summary.outcome == :timeout
    assert summary.drive.received == 2
    assert summary.sensors.received == 0
    assert summary.sensors.missing == 2
    assert summary.sensors.finished == false
    send(sensors, :stop)
  end

  test "a lost traffic-start request is retried before the run deadline" do
    parent = self()

    drive =
      spawn(fn ->
        receive do
          {:robot_traffic_start, _starter, _collector, run_id, _count, _interval_ms, _bytes,
           _ack_timeout_ms, _ack_retries} ->
            send(parent, {:start_attempt, :drive, run_id, 1})
        end

        receive do
          {:robot_traffic_start, starter, collector, run_id, count, interval_ms, bytes,
           ack_timeout_ms, ack_retries} ->
            send(parent, {:start_attempt, :drive, run_id, 2})
            send(starter, {:robot_traffic_start_ack, :drive, run_id})

            ConcurrentTraffic.start_producer(
              collector,
              :drive,
              run_id,
              count,
              interval_ms,
              bytes,
              ack_timeout_ms,
              ack_retries
            )
        end
      end)

    sensors = fake_remote(:sensors)

    ConcurrentTraffic.start(self(), [{:drive, drive}, {:sensors, sensors}],
      samples: 1,
      drive_interval_ms: 1,
      sensors_interval_ms: 1,
      payload_bytes: 0,
      timeout_ms: 500,
      ack_timeout_ms: 20,
      ack_retries: 1
    )

    assert_receive {:start_attempt, :drive, run_id, 1}, 100
    assert_receive {:start_attempt, :drive, ^run_id, 2}, 100
    assert_receive {:robot_traffic_complete, ^run_id, summary}, 1_000
    assert summary.outcome == :complete
    assert summary.drive.received == 1
    assert summary.sensors.received == 1
  end

  test "a producer retries the same sample after an ACK timeout" do
    producer =
      ConcurrentTraffic.start_producer(self(), :drive, 123, 1, 1, 4, 20, 1, self())

    monitor = Process.monitor(producer)

    assert_receive {:robot_traffic_started, ^producer, :drive, 123}
    send(producer, {:robot_traffic_ack, :started, :drive, 123})

    assert_receive {:robot_traffic_sample, ^producer, :drive, 123, 1, payload}
    assert byte_size(payload) == 4

    assert_receive {:robot_traffic_ack_timeout, ^producer, :drive, 123, {:sample, 1}}, 100
    assert_receive {:robot_traffic_sample, ^producer, :drive, 123, 1, ^payload}, 100
    refute_receive {:robot_traffic_ack_timeout, ^producer, :drive, 123, {:sample, 1}}, 5
    send(producer, {:robot_traffic_ack, :sample, :drive, 123, 1})

    assert_receive {:robot_traffic_finished, ^producer, :drive, 123}
    send(producer, {:robot_traffic_ack, :finished, :drive, 123})
    assert_receive {:DOWN, ^monitor, :process, ^producer, :normal}
  end

  test "a producer accepts the bounded 256-sample long-run profile" do
    producer = ConcurrentTraffic.start_producer(self(), :sensors, 456, 256, 1, 0, 100, 0)
    monitor = Process.monitor(producer)

    assert_receive {:robot_traffic_started, ^producer, :sensors, 456}
    send(producer, {:robot_traffic_ack, :started, :sensors, 456})

    Enum.each(1..256, fn sequence ->
      assert_receive {:robot_traffic_sample, ^producer, :sensors, 456, ^sequence, <<>>}, 100
      send(producer, {:robot_traffic_ack, :sample, :sensors, 456, sequence})
    end)

    assert_receive {:robot_traffic_finished, ^producer, :sensors, 456}
    send(producer, {:robot_traffic_ack, :finished, :sensors, 456})
    assert_receive {:DOWN, ^monitor, :process, ^producer, :normal}
  end

  defp fake_remote(role) do
    spawn(fn ->
      receive do
        {:robot_traffic_start, starter, collector, run_id, count, interval_ms, bytes,
         ack_timeout_ms, ack_retries} ->
          send(starter, {:robot_traffic_start_ack, role, run_id})

          ConcurrentTraffic.start_producer(
            collector,
            role,
            run_id,
            count,
            interval_ms,
            bytes,
            ack_timeout_ms,
            ack_retries
          )
      end
    end)
  end
end
