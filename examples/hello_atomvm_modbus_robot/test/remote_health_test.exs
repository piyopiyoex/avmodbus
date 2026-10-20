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
  end

  test "reconnection changes generation without resetting the boot restart budget" do
    health = RemoteHealth.new(10, 1_000, enabled: true, ack_timeout_ms: 100, max_restarts: 2)
    assert {:restart, restarting} = RemoteHealth.evaluate(health, 1_101)

    reconnected = RemoteHealth.reconnected(restarting, 11, 1_120)
    assert reconnected.connection_id == 11
    assert reconnected.last_ack_ms == 1_120
    assert reconnected.restarts == 1
  end
end
