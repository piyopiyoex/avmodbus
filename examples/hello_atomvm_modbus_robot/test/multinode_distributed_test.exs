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

  test "classifies first, duplicate, and replacement readiness announcements" do
    first_pid = self()
    replacement_pid = spawn(fn -> :ok end)
    remotes = %{drive: %{pid: first_pid, boot_id: 100}, sensors: nil}

    assert MultinodeDistributed.classify_readiness(
             remotes,
             :drive,
             :"drive@modbus.local",
             first_pid,
             100
           ) == :duplicate

    assert MultinodeDistributed.classify_readiness(
             remotes,
             :drive,
             :"drive@modbus.local",
             replacement_pid,
             100
           ) == :new

    assert MultinodeDistributed.classify_readiness(
             remotes,
             :sensors,
             :"sensors@modbus.local",
             replacement_pid,
             200
           ) == :new
  end

  test "a new boot session is new even when AtomVM reuses the same pid" do
    remotes = %{drive: %{pid: self(), boot_id: 100}, sensors: nil}

    assert MultinodeDistributed.classify_readiness(
             remotes,
             :drive,
             :"drive@modbus.local",
             self(),
             101
           ) == :new
  end

  test "rejects readiness from a node name that does not match its role" do
    assert MultinodeDistributed.classify_readiness(
             %{drive: nil, sensors: nil},
             :drive,
             :"sensors@modbus.local",
             self(),
             100
           ) == :unexpected
  end
end
