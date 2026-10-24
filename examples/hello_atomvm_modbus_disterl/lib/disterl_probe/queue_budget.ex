defmodule DisterlProbe.QueueBudget do
  @moduledoc """
  複数の`ModbusUART` adapterが共有するoutgoing queue budgetです。

  streamごとの`Channel`上限とは別に、登録されたowner全体のpayload byte数と
  chunk数を原子的に制限します。この値はVM全体のmemory使用量ではありません。
  """

  use GenServer

  @doc "共有budget processを開始します。"
  def start_link(options) when is_list(options) do
    max_bytes = Keyword.get(options, :max_queued_bytes)
    max_chunks = Keyword.get(options, :max_queued_chunks)

    if positive_integer?(max_bytes) and positive_integer?(max_chunks) do
      GenServer.start_link(__MODULE__, {max_bytes, max_chunks})
    else
      {:error, :invalid_queue_budget_limits}
    end
  end

  @doc "ownerのqueueへ追加する容量を予約します。"
  def reserve(pid, owner, bytes, chunks)
      when is_pid(pid) and is_pid(owner) and is_integer(bytes) and bytes >= 0 and
             is_integer(chunks) and chunks >= 0,
      do: GenServer.call(pid, {:reserve, owner, bytes, chunks}, :infinity)

  @doc "ownerの現在量へ同期し、ACKやsession resetによる解放を反映します。"
  def set_usage(pid, owner, bytes, chunks)
      when is_pid(pid) and is_pid(owner) and is_integer(bytes) and bytes >= 0 and
             is_integer(chunks) and chunks >= 0,
      do: GenServer.call(pid, {:set_usage, owner, bytes, chunks}, :infinity)

  @doc "ownerが確保した容量をすべて解放します。"
  def release(pid, owner) when is_pid(pid) and is_pid(owner),
    do: GenServer.call(pid, {:release, owner}, :infinity)

  @doc "現在量、上限、high-water、拒否回数を返します。"
  def snapshot(pid) when is_pid(pid), do: GenServer.call(pid, :snapshot, :infinity)

  @impl true
  def init({max_bytes, max_chunks}) do
    {:ok,
     %{
       max_queued_bytes: max_bytes,
       max_queued_chunks: max_chunks,
       queued_bytes: 0,
       queued_chunks: 0,
       max_queued_bytes_observed: 0,
       max_queued_chunks_observed: 0,
       rejected: 0,
       owners: %{},
       monitors: %{}
     }}
  end

  @impl true
  def handle_call({:reserve, owner, bytes, chunks}, _from, state) do
    current = Map.get(state.owners, owner, %{bytes: 0, chunks: 0, monitor: nil})
    set_owner_usage(state, owner, current.bytes + bytes, current.chunks + chunks)
  end

  def handle_call({:set_usage, owner, bytes, chunks}, _from, state),
    do: set_owner_usage(state, owner, bytes, chunks)

  def handle_call({:release, owner}, _from, state),
    do: set_owner_usage(state, owner, 0, 0)

  def handle_call(:snapshot, _from, state), do: {:reply, public_snapshot(state), state}

  @impl true
  def handle_info({:DOWN, reference, :process, _pid, _reason}, state) do
    case Map.get(state.monitors, reference) do
      nil -> {:noreply, state}
      owner -> {:noreply, release_owner(state, owner)}
    end
  end

  defp set_owner_usage(state, owner, bytes, chunks) do
    current = Map.get(state.owners, owner, %{bytes: 0, chunks: 0, monitor: nil})
    queued_bytes = state.queued_bytes - current.bytes + bytes
    queued_chunks = state.queued_chunks - current.chunks + chunks

    if queued_bytes <= state.max_queued_bytes and queued_chunks <= state.max_queued_chunks do
      {owners, monitors} = put_owner(state, owner, current, bytes, chunks)

      next = %{
        state
        | owners: owners,
          monitors: monitors,
          queued_bytes: queued_bytes,
          queued_chunks: queued_chunks,
          max_queued_bytes_observed: max(state.max_queued_bytes_observed, queued_bytes),
          max_queued_chunks_observed: max(state.max_queued_chunks_observed, queued_chunks)
      }

      {:reply, :ok, next}
    else
      {:reply, {:error, :global_queue_full}, %{state | rejected: state.rejected + 1}}
    end
  end

  defp put_owner(state, owner, current, 0, 0) do
    if current.monitor != nil, do: :erlang.demonitor(current.monitor, [:flush])

    {
      Map.delete(state.owners, owner),
      if(current.monitor == nil,
        do: state.monitors,
        else: Map.delete(state.monitors, current.monitor)
      )
    }
  end

  defp put_owner(state, owner, %{monitor: nil}, bytes, chunks) do
    reference = Process.monitor(owner)

    {
      Map.put(state.owners, owner, %{bytes: bytes, chunks: chunks, monitor: reference}),
      Map.put(state.monitors, reference, owner)
    }
  end

  defp put_owner(state, owner, current, bytes, chunks) do
    {
      Map.put(state.owners, owner, %{current | bytes: bytes, chunks: chunks}),
      state.monitors
    }
  end

  defp release_owner(state, owner) do
    current = Map.get(state.owners, owner)

    if current == nil do
      state
    else
      %{
        state
        | owners: Map.delete(state.owners, owner),
          monitors: Map.delete(state.monitors, current.monitor),
          queued_bytes: state.queued_bytes - current.bytes,
          queued_chunks: state.queued_chunks - current.chunks
      }
    end
  end

  defp public_snapshot(state) do
    %{
      queued_bytes: state.queued_bytes,
      queued_chunks: state.queued_chunks,
      max_queued_bytes: state.max_queued_bytes,
      max_queued_chunks: state.max_queued_chunks,
      max_queued_bytes_observed: state.max_queued_bytes_observed,
      max_queued_chunks_observed: state.max_queued_chunks_observed,
      active_owners: map_size(state.owners),
      rejected: state.rejected
    }
  end

  defp positive_integer?(value), do: is_integer(value) and value > 0
end
