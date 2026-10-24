defmodule DisterlProbe.PollSchedulerTest do
  use ExUnit.Case, async: true

  alias DisterlProbe.PollScheduler

  test "dispatches one poll at a time in registration order" do
    parent = self()
    drive = forward_polls(parent, :drive)
    sensors = forward_polls(parent, :sensors)
    {:ok, scheduler} = PollScheduler.start_link(delay_ms: 0)

    assert :ok = PollScheduler.register(scheduler, drive)
    assert :ok = PollScheduler.register(scheduler, sensors)
    assert :ok = PollScheduler.start(scheduler)

    assert_receive {:poll, :drive}
    refute_receive {:poll, :sensors}

    assert :ok = PollScheduler.complete(scheduler, drive)
    assert_receive {:poll, :sensors}

    assert :ok = PollScheduler.complete(scheduler, sensors)
    assert_receive {:poll, :drive}
  end

  test "rejects invalid lifecycle transitions" do
    {:ok, empty} = PollScheduler.start_link()
    assert PollScheduler.start(empty) == {:error, :no_adapters}

    {:ok, scheduler} = PollScheduler.start_link()
    assert :ok = PollScheduler.register(scheduler, self())
    assert PollScheduler.register(scheduler, self()) == {:error, :already_registered}
    assert :ok = PollScheduler.start(scheduler)
    assert PollScheduler.start(scheduler) == {:error, :already_started}
    assert PollScheduler.register(scheduler, self()) == {:error, :already_started}
    assert_receive :poll
  end

  test "ignores completion from an adapter that does not own the token" do
    parent = self()
    drive = forward_polls(parent, :drive)
    sensors = forward_polls(parent, :sensors)
    {:ok, scheduler} = PollScheduler.start_link(delay_ms: 0)

    :ok = PollScheduler.register(scheduler, drive)
    :ok = PollScheduler.register(scheduler, sensors)
    :ok = PollScheduler.start(scheduler)
    assert_receive {:poll, :drive}

    :ok = PollScheduler.complete(scheduler, sensors)
    refute_receive {:poll, :sensors}

    :ok = PollScheduler.complete(scheduler, drive)
    assert_receive {:poll, :sensors}
  end

  test "preserves round-robin order from one to 32 adapters" do
    Enum.each([1, 2, 3, 8, 32], fn count ->
      parent = self()

      adapters =
        Enum.map(1..count, fn index ->
          role = {:peer, index}
          {forward_polls(parent, role), role}
        end)

      {:ok, scheduler} = PollScheduler.start_link(delay_ms: 0)

      Enum.each(adapters, fn {adapter, _role} ->
        assert :ok = PollScheduler.register(scheduler, adapter)
      end)

      assert :ok = PollScheduler.start(scheduler)

      Enum.each(1..4, fn round ->
        adapters
        |> Enum.with_index()
        |> Enum.each(fn {{adapter, role}, index} ->
          assert_receive {:poll, ^role}

          unless round == 4 and index == count - 1 do
            assert :ok = PollScheduler.complete(scheduler, adapter)
          end
        end)
      end)

      refute_receive {:poll, _role}
      GenServer.stop(scheduler)
      Enum.each(adapters, fn {adapter, _role} -> send(adapter, :stop) end)
    end)
  end

  defp forward_polls(parent, role) do
    spawn(fn -> forward_loop(parent, role) end)
  end

  defp forward_loop(parent, role) do
    receive do
      :poll ->
        send(parent, {:poll, role})
        forward_loop(parent, role)

      :stop ->
        :ok
    end
  end
end
