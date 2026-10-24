defmodule RobotSim.RemoteHealthTest do
  use ExUnit.Case, async: true

  alias RobotSim.RemoteHealth

  test "disabled health never requests a restart" do
    health = RemoteHealth.new(10, 1_000, enabled: false, ack_timeout_ms: 100)
    assert {:disabled, ^health} = RemoteHealth.evaluate(health, 10_000)
  end

  test "health remains valid at the exact ACK deadline" do
    health = RemoteHealth.new(10, 1_000, enabled: true, ack_timeout_ms: 100)
    assert {:healthy, ^health} = RemoteHealth.evaluate(health, 1_100)
  end

  test "an overdue ACK consumes one bounded restart" do
    health = RemoteHealth.new(10, 1_000, enabled: true, ack_timeout_ms: 100, max_restarts: 2)
    assert {:restart, next} = RemoteHealth.evaluate(health, 1_101)
    assert next.restarts == 1
    assert next.last_ack_ms == 1_101
  end

  test "restart exhaustion is reported once while the outage continues" do
    health = RemoteHealth.new(10, 1_000, enabled: true, ack_timeout_ms: 100, max_restarts: 0)
    assert {:exhausted, exhausted} = RemoteHealth.evaluate(health, 1_101)
    assert {:waiting, ^exhausted} = RemoteHealth.evaluate(exhausted, 1_202)
  end

  test "stale connection ACKs do not refresh health" do
    health = RemoteHealth.new(10, 1_000, enabled: true, ack_timeout_ms: 100)
    assert RemoteHealth.acknowledge(health, 9, 1_050) == health

    refreshed = RemoteHealth.acknowledge(health, 10, 1_050)
    assert refreshed.last_ack_ms == 1_050
    assert refreshed.ack_count == 1
    assert refreshed.connection_ack_count == 1
    assert refreshed.max_ack_gap_ms == 0
  end

  test "records the maximum ACK gap after the initial connection ACK" do
    health = RemoteHealth.new(10, 1_000, enabled: true, ack_timeout_ms: 1_000)
    first = RemoteHealth.acknowledge(health, 10, 1_080)
    second = RemoteHealth.acknowledge(first, 10, 1_200)
    third = RemoteHealth.acknowledge(second, 10, 1_290)

    assert third.ack_count == 3
    assert third.connection_ack_count == 3
    assert third.max_ack_gap_ms == 120
  end

  test "reconnection changes generation without resetting the boot restart budget" do
    health = RemoteHealth.new(10, 1_000, enabled: true, ack_timeout_ms: 100, max_restarts: 2)
    assert {:restart, restarting} = RemoteHealth.evaluate(health, 1_101)

    reconnected = RemoteHealth.reconnected(restarting, 11, 1_120)
    assert reconnected.connection_id == 11
    assert reconnected.last_ack_ms == 1_120
    assert reconnected.restarts == 1
    assert reconnected.connection_ack_count == 0
  end

  test "reconnection preserves the boot-wide ACK gap high-water mark" do
    health = RemoteHealth.new(10, 1_000, enabled: true, ack_timeout_ms: 1_000)
    first = RemoteHealth.acknowledge(health, 10, 1_010)
    measured = RemoteHealth.acknowledge(first, 10, 1_210)
    reconnected = RemoteHealth.reconnected(measured, 11, 1_300)
    first_after_reconnect = RemoteHealth.acknowledge(reconnected, 11, 1_500)

    assert first_after_reconnect.ack_count == 3
    assert first_after_reconnect.connection_ack_count == 1
    assert first_after_reconnect.max_ack_gap_ms == 200
  end
end
