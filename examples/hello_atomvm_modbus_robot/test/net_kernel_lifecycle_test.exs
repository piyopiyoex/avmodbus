defmodule RobotSim.NetKernelLifecycleTest do
  use ExUnit.Case, async: true

  alias RobotSim.NetKernelLifecycle

  test "停止完了後にkernelを再開する" do
    owner = self()
    {:ok, lookup} = Agent.start_link(fn -> [:running, nil] end)

    assert :ok =
             NetKernelLifecycle.restart(
               fn ->
                 send(owner, :start_called)
                 :ok
               end,
               stop_fun: fn -> :ok end,
               whereis_fun: fn -> next_lookup(lookup) end,
               wait_fun: fn milliseconds -> send(owner, {:waited, milliseconds}) end,
               trace_fun: trace_to(owner),
               poll_ms: 7,
               poll_attempts: 2
             )

    assert_received {:waited, 7}
    assert_received :start_called

    assert traced_events() == [
             :kernel_stop_requested,
             :kernel_stop_completed,
             :kernel_start_started,
             :kernel_start_succeeded
           ]
  end

  test "stop APIの失敗を再開失敗と分けて返す" do
    owner = self()

    assert {:error, {:net_kernel_stop_failed, :denied}} =
             NetKernelLifecycle.restart(fn -> flunk("再開してはいけない") end,
               stop_fun: fn -> :denied end,
               trace_fun: trace_to(owner)
             )

    assert_receive {:trace, :kernel_stop_failed, [reason: {:net_kernel_stop_failed, :denied}]}
  end

  test "登録解除されないprocessをbounded timeoutとして返す" do
    owner = self()
    pid = self()

    assert {:error, {:net_kernel_stop_timeout, ^pid}} =
             NetKernelLifecycle.restart(fn -> flunk("再開してはいけない") end,
               stop_fun: fn -> :ok end,
               whereis_fun: fn -> pid end,
               wait_fun: fn _milliseconds -> :ok end,
               trace_fun: trace_to(owner),
               poll_attempts: 2
             )

    assert traced_events() == [:kernel_stop_requested, :kernel_stop_failed]
  end

  test "kernel再開失敗をそのまま返す" do
    owner = self()

    assert {:error, :setup_timeout} =
             NetKernelLifecycle.restart(fn -> {:error, :setup_timeout} end,
               stop_fun: fn -> :ok end,
               whereis_fun: fn -> nil end,
               trace_fun: trace_to(owner)
             )

    assert traced_events() == [
             :kernel_stop_requested,
             :kernel_stop_completed,
             :kernel_start_started,
             :kernel_start_failed
           ]
  end

  defp next_lookup(agent) do
    Agent.get_and_update(agent, fn
      [next | rest] -> {next, rest}
      [] -> {nil, []}
    end)
  end

  defp trace_to(owner) do
    fn event, fields ->
      send(owner, {:trace, event, fields})
      :ok
    end
  end

  defp traced_events(events \\ []) do
    receive do
      {:trace, event, _fields} -> traced_events([event | events])
    after
      0 -> Enum.reverse(events)
    end
  end
end
