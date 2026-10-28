defmodule RobotSim.RuntimeSnapshot do
  @moduledoc """
  AtomVM上のheapとlifecycle owner processを同じ時点で観測します。

  全processのmailbox走査は計測自体の負荷が大きいため行わず、VM全体のprocess数と
  呼び出しprocessのmailbox長だけを記録します。
  """

  alias DisterlProbe.MemorySnapshot

  @type t :: %{
          free_heap_bytes: non_neg_integer(),
          largest_free_block_bytes: non_neg_integer(),
          minimum_free_heap_bytes: non_neg_integer(),
          process_count: non_neg_integer(),
          owner_message_queue_len: non_neg_integer()
        }

  @doc "AtomVM上ではruntime snapshotを返し、host上では`nil`を返します。"
  @spec capture() :: t() | nil
  def capture do
    case MemorySnapshot.capture() do
      nil ->
        nil

      memory ->
        Map.merge(memory, %{
          process_count: :erlang.system_info(:process_count),
          owner_message_queue_len: message_queue_len(self())
        })
    end
  end

  @doc "Runtime snapshotを機械処理しやすいfield列へ整形します。"
  @spec format(t() | nil) :: String.t()
  def format(nil), do: "free_heap_bytes=unavailable"

  def format(snapshot) do
    "free_heap_bytes=#{snapshot.free_heap_bytes} " <>
      "largest_free_block_bytes=#{snapshot.largest_free_block_bytes} " <>
      "minimum_free_heap_bytes=#{snapshot.minimum_free_heap_bytes} " <>
      "process_count=#{snapshot.process_count} " <>
      "owner_message_queue_len=#{snapshot.owner_message_queue_len}"
  end

  defp message_queue_len(pid) do
    case :erlang.process_info(pid, :message_queue_len) do
      {:message_queue_len, length} -> length
      _other -> 0
    end
  end
end
