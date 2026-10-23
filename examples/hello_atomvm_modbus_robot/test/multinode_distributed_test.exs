defmodule RobotSim.MultinodeDistributedTest do
  use ExUnit.Case, async: true

  alias RobotSim.MultinodeDistributed

  test "each role has a fixed and distinct node name" do
    nodes = Enum.map([:controller, :drive, :sensors], &MultinodeDistributed.identity/1)

    assert nodes == [
             :"controller@modbus.local",
             :"drive@modbus.local",
             :"sensors@modbus.local"
           ]

    assert Enum.uniq(nodes) == nodes
  end

  test "logical stream order matches the physical multidrop schedule" do
    assert MultinodeDistributed.targets() == [{:drive, 1}, {:sensors, 2}]
    assert MultinodeDistributed.targets(11, 22) == [{:drive, 11}, {:sensors, 22}]
  end

  test "soak probes alternate which role goes first" do
    assert MultinodeDistributed.soak_targets(1) == [:drive, :sensors]
    assert MultinodeDistributed.soak_targets(2) == [:sensors, :drive]
    assert MultinodeDistributed.soak_targets(3) == [:drive, :sensors]
  end

  test "response fault is one-shot across distribution restarts by default" do
    assert MultinodeDistributed.restart_fault_drop_responses(180, false) == 0
    assert MultinodeDistributed.restart_fault_drop_responses(0, false) == 0
  end

  test "response fault can explicitly rearm across distribution restarts" do
    assert MultinodeDistributed.restart_fault_drop_responses(180, true) == 180
  end

  test "a repeated traffic start is classified as a duplicate" do
    assert MultinodeDistributed.classify_traffic_start(nil, 123) == :new
    assert MultinodeDistributed.classify_traffic_start(123, 123) == :duplicate
    assert MultinodeDistributed.classify_traffic_start(123, 456) == :new
  end

  test "classifies first, duplicate, and replacement readiness announcements" do
    first_pid = self()
    replacement_pid = spawn(fn -> :ok end)
    remotes = %{drive: %{pid: first_pid, boot_id: 100, connection_id: 1_000}, sensors: nil}

    assert MultinodeDistributed.classify_readiness(
             remotes,
             :drive,
             :"drive@modbus.local",
             first_pid,
             100,
             1_000
           ) == :duplicate

    assert MultinodeDistributed.classify_readiness(
             remotes,
             :drive,
             :"drive@modbus.local",
             replacement_pid,
             100,
             1_000
           ) == :new

    assert MultinodeDistributed.classify_readiness(
             remotes,
             :sensors,
             :"sensors@modbus.local",
             replacement_pid,
             200,
             2_000
           ) == :new
  end

  test "duplicate readiness ignores lease metadata" do
    remotes = %{
      drive: %{pid: self(), boot_id: 100, connection_id: 1_000, last_seen_ms: 1_000},
      sensors: nil
    }

    assert MultinodeDistributed.classify_readiness(
             remotes,
             :drive,
             :"drive@modbus.local",
             self(),
             100,
             1_000
           ) == :duplicate
  end

  test "expired readiness leases remove only stale remotes" do
    remotes = %{
      drive: %{pid: self(), boot_id: 100, connection_id: 1_000, last_seen_ms: 1_000},
      sensors: %{pid: self(), boot_id: 200, connection_id: 2_000, last_seen_ms: 4_500}
    }

    assert {[:drive], next_remotes} =
             MultinodeDistributed.expire_stale_remotes(remotes, 5_001, 3_000)

    assert next_remotes.drive == nil
    assert next_remotes.sensors == remotes.sensors
  end

  test "a readiness lease remains valid at its exact deadline" do
    remotes = %{
      drive: %{pid: self(), boot_id: 101, connection_id: 1_000, last_seen_ms: 2_000},
      sensors: nil
    }

    assert MultinodeDistributed.expire_stale_remotes(remotes, 5_000, 3_000) ==
             {[], remotes}
  end

  test "a new boot session is new even when AtomVM reuses the same pid" do
    remotes = %{drive: %{pid: self(), boot_id: 100, connection_id: 1_000}, sensors: nil}

    assert MultinodeDistributed.classify_readiness(
             remotes,
             :drive,
             :"drive@modbus.local",
             self(),
             101,
             1_000
           ) == :new
  end

  test "a new distribution connection is new within the same board boot" do
    remotes = %{drive: %{pid: self(), boot_id: 100, connection_id: 1_000}, sensors: nil}

    assert MultinodeDistributed.classify_readiness(
             remotes,
             :drive,
             :"drive@modbus.local",
             self(),
             100,
             1_001
           ) == :new
  end

  test "rejects readiness from a node name that does not match its role" do
    assert MultinodeDistributed.classify_readiness(
             %{drive: nil, sensors: nil},
             :drive,
             :"sensors@modbus.local",
             self(),
             100,
             1_000
           ) == :unexpected
  end

  test "retries an in-flight soak probe when its remote boot session changes" do
    old_pid = self()
    new_pid = spawn(fn -> :ok end)

    remotes =
      %{drive: %{pid: old_pid, boot_id: 100, connection_id: 1_000}, sensors: nil}

    assert {:retry, next_remotes} =
             MultinodeDistributed.soak_readiness_transition(
               remotes,
               :drive,
               :drive,
               :"drive@modbus.local",
               new_pid,
               101,
               1_001
             )

    assert next_remotes.drive == %{pid: new_pid, boot_id: 101, connection_id: 1_001}
  end

  test "continues waiting when the other soak role reconnects" do
    new_pid = spawn(fn -> :ok end)
    remotes = %{drive: nil, sensors: nil}

    assert {:continue, next_remotes} =
             MultinodeDistributed.soak_readiness_transition(
               remotes,
               :drive,
               :sensors,
               :"sensors@modbus.local",
               new_pid,
               200,
               2_000
             )

    assert next_remotes.sensors == %{pid: new_pid, boot_id: 200, connection_id: 2_000}
  end

  test "does not retry an in-flight soak probe for a duplicate heartbeat" do
    remotes = %{drive: %{pid: self(), boot_id: 100, connection_id: 1_000}, sensors: nil}

    assert {:duplicate, ^remotes} =
             MultinodeDistributed.soak_readiness_transition(
               remotes,
               :drive,
               :drive,
               :"drive@modbus.local",
               self(),
               100,
               1_000
             )
  end
end
