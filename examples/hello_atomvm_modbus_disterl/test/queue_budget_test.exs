defmodule DisterlProbe.QueueBudgetTest do
  use ExUnit.Case, async: true

  alias DisterlProbe.QueueBudget

  test "複数ownerの合計byte数とchunk数を原子的に制限する" do
    {:ok, budget} = QueueBudget.start_link(max_queued_bytes: 100, max_queued_chunks: 4)
    drive = start_owner()
    sensors = start_owner()

    assert :ok = QueueBudget.reserve(budget, drive, 60, 2)
    assert :ok = QueueBudget.reserve(budget, sensors, 40, 1)
    assert {:error, :global_queue_full} = QueueBudget.reserve(budget, sensors, 1, 0)
    assert {:error, :global_queue_full} = QueueBudget.reserve(budget, drive, 0, 2)

    assert %{
             queued_bytes: 100,
             queued_chunks: 3,
             max_queued_bytes_observed: 100,
             max_queued_chunks_observed: 3,
             active_owners: 2,
             rejected: 2
           } = QueueBudget.snapshot(budget)
  end

  test "ACK相当の同期、session reset、adapter終了で容量を解放する" do
    {:ok, budget} = QueueBudget.start_link(max_queued_bytes: 200, max_queued_chunks: 8)
    drive = start_owner()
    sensors = start_owner()

    assert :ok = QueueBudget.reserve(budget, drive, 120, 3)
    assert :ok = QueueBudget.reserve(budget, sensors, 60, 2)

    assert :ok = QueueBudget.set_usage(budget, drive, 40, 1)
    assert %{queued_bytes: 100, queued_chunks: 3} = QueueBudget.snapshot(budget)

    assert :ok = QueueBudget.set_usage(budget, sensors, 0, 0)

    assert %{queued_bytes: 40, queued_chunks: 1, active_owners: 1} =
             QueueBudget.snapshot(budget)

    assert :ok = QueueBudget.release(budget, drive)

    assert %{queued_bytes: 0, queued_chunks: 0, active_owners: 0} =
             QueueBudget.snapshot(budget)
  end

  test "拒否後も予約前の使用量を維持する" do
    {:ok, budget} = QueueBudget.start_link(max_queued_bytes: 64, max_queued_chunks: 2)
    drive = start_owner()

    assert :ok = QueueBudget.reserve(budget, drive, 32, 1)
    assert {:error, :global_queue_full} = QueueBudget.set_usage(budget, drive, 65, 1)

    assert %{queued_bytes: 32, queued_chunks: 1, rejected: 1} =
             QueueBudget.snapshot(budget)
  end

  test "32 ownerが同時に上限へ達しても合計量を超えない" do
    {:ok, budget} = QueueBudget.start_link(max_queued_bytes: 256, max_queued_chunks: 32)
    owners = Enum.map(1..33, fn _index -> start_owner() end)

    Enum.each(Enum.take(owners, 32), fn owner ->
      assert :ok = QueueBudget.reserve(budget, owner, 8, 1)
    end)

    extra_owner = Enum.at(owners, 32)
    assert {:error, :global_queue_full} = QueueBudget.reserve(budget, extra_owner, 1, 1)

    assert %{queued_bytes: 256, queued_chunks: 32, active_owners: 32} =
             QueueBudget.snapshot(budget)

    Enum.each(Enum.take(owners, 16), fn owner ->
      assert :ok = QueueBudget.release(budget, owner)
    end)

    assert :ok = QueueBudget.reserve(budget, extra_owner, 128, 16)

    assert %{queued_bytes: 256, queued_chunks: 32, active_owners: 17} =
             QueueBudget.snapshot(budget)
  end

  test "不正な上限を拒否する" do
    assert QueueBudget.start_link(max_queued_bytes: 0, max_queued_chunks: 1) ==
             {:error, :invalid_queue_budget_limits}

    assert QueueBudget.start_link(max_queued_bytes: 1, max_queued_chunks: 0) ==
             {:error, :invalid_queue_budget_limits}
  end

  test "ownerが異常終了しても予約を解放する" do
    {:ok, budget} = QueueBudget.start_link(max_queued_bytes: 64, max_queued_chunks: 2)
    owner = start_owner()
    assert :ok = QueueBudget.reserve(budget, owner, 32, 1)

    Process.exit(owner, :kill)
    assert_budget_released(budget, 20)
  end

  defp start_owner do
    owner =
      spawn(fn ->
        receive do
          :stop -> :ok
        end
      end)

    on_exit(fn -> if Process.alive?(owner), do: send(owner, :stop) end)
    owner
  end

  defp assert_budget_released(_budget, 0), do: flunk("ownerの予約が解放されませんでした")

  defp assert_budget_released(budget, attempts) do
    case QueueBudget.snapshot(budget) do
      %{queued_bytes: 0, queued_chunks: 0, active_owners: 0} ->
        :ok

      _snapshot ->
        Process.sleep(1)
        assert_budget_released(budget, attempts - 1)
    end
  end
end
