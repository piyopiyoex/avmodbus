defmodule RobotSim.DistributedTest do
  use ExUnit.Case, async: true

  alias RobotSim.Distributed

  test "controller and drive identities are complementary" do
    controller = Distributed.identity(:controller)
    drive = Distributed.identity(:drive)

    assert controller.node == drive.peer
    assert controller.peer == drive.node
    assert controller.role == :controller
    assert drive.role == :drive
  end
end
