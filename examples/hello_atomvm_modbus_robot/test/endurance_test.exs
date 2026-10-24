defmodule RobotSim.EnduranceTest do
  use ExUnit.Case, async: true

  alias RobotSim.Endurance

  test "runを1本ずつ開始し結果をboundedに集計する" do
    plan = Endurance.new(3)

    assert {:ok, 1, running} = Endurance.start_next(plan)
    assert Endurance.start_next(running) == {:error, :run_active}
    assert {:ok, 1, :continue, plan} = Endurance.complete(running, :complete)

    assert {:ok, 2, running} = Endurance.start_next(plan)
    assert {:ok, 2, :continue, plan} = Endurance.complete(running, :timeout)

    assert {:ok, 3, running} = Endurance.start_next(plan)
    assert {:ok, 3, :complete, plan} = Endurance.complete(running, :cancelled)
    assert Endurance.start_next(plan) == {:error, :complete}

    assert Endurance.summary(plan) == %{
             total_runs: 3,
             completed_runs: 3,
             complete: 1,
             timeout: 1,
             other: 1
           }
  end

  test "active runがない完了通知を拒否する" do
    assert Endurance.complete(Endurance.new(1), :complete) == {:error, :no_active_run}
  end
end
