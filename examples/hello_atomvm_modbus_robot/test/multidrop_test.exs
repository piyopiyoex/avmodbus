defmodule RobotSim.MultidropTest do
  use ExUnit.Case, async: true

  alias RobotSim.Multidrop

  test "the controller polls Drive before Sensors" do
    assert Multidrop.targets() == [{:drive, 1}, {:sensors, 2}]
    assert Multidrop.targets(11, 22) == [{:drive, 11}, {:sensors, 22}]
  end

  test "each server exposes a distinct role and unit identity" do
    assert Multidrop.identity_registers(:drive, 1) == [1, 1]
    assert Multidrop.identity_registers(:sensors, 2) == [2, 2]
  end

  test "valid replies are accepted" do
    assert Multidrop.validate_reply(:drive, 1, {:ok, [1, 1]}) == :ok
    assert Multidrop.validate_reply(:sensors, 2, {:ok, [2, 2]}) == :ok
  end

  test "wrong-unit and transport replies are rejected with context" do
    assert Multidrop.validate_reply(:sensors, 2, {:ok, [1, 1]}) ==
             {:error, {:unexpected_registers, :sensors, 2, [2, 2], [1, 1]}}

    assert Multidrop.validate_reply(:drive, 1, {:error, :timeout}) ==
             {:error, {:request_failed, :drive, 1, :timeout}}
  end
end
