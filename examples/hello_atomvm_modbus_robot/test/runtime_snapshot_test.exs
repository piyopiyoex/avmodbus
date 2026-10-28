defmodule RobotSim.RuntimeSnapshotTest do
  use ExUnit.Case, async: true

  alias RobotSim.RuntimeSnapshot

  test "runtime snapshotを安定したfield順で整形する" do
    snapshot = %{
      free_heap_bytes: 80_000,
      largest_free_block_bytes: 60_000,
      minimum_free_heap_bytes: 70_000,
      process_count: 24,
      owner_message_queue_len: 3
    }

    assert RuntimeSnapshot.format(snapshot) ==
             "free_heap_bytes=80000 largest_free_block_bytes=60000 " <>
               "minimum_free_heap_bytes=70000 process_count=24 owner_message_queue_len=3"
  end

  test "hostではsnapshotを取得しない" do
    assert RuntimeSnapshot.capture() == nil
    assert RuntimeSnapshot.format(nil) == "free_heap_bytes=unavailable"
  end
end
