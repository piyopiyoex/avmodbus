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
end
