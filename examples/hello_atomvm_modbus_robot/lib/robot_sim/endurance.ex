defmodule RobotSim.Endurance do
  @moduledoc """
  Active trafficとidleを反復するendurance runの小さな状態機械です。

  wall clockやtransportを所有せず、同時に1 runだけを開始し、完了結果をboundedな
  集計値として保持します。
  """

  @doc "指定した回数のrun planを作成します。"
  def new(total_runs) when is_integer(total_runs) and total_runs > 0 do
    %{
      total_runs: total_runs,
      next_run: 1,
      active_run: nil,
      completed_runs: 0,
      complete: 0,
      timeout: 0,
      other: 0
    }
  end

  @doc "次のrunを開始します。"
  def start_next(%{active_run: nil, next_run: next_run, total_runs: total_runs} = state)
      when next_run <= total_runs do
    {:ok, next_run, %{state | active_run: next_run, next_run: next_run + 1}}
  end

  def start_next(%{active_run: active_run}) when active_run != nil,
    do: {:error, :run_active}

  def start_next(_state), do: {:error, :complete}

  @doc "現在のrunを完了し、結果件数を更新します。"
  def complete(%{active_run: nil}, _outcome), do: {:error, :no_active_run}

  def complete(state, outcome) do
    next = %{
      increment_outcome(state, outcome)
      | active_run: nil,
        completed_runs: state.completed_runs + 1
    }

    status = if next.completed_runs == next.total_runs, do: :complete, else: :continue
    {:ok, state.active_run, status, next}
  end

  @doc "run件数と結果を返します。"
  def summary(state) do
    %{
      total_runs: state.total_runs,
      completed_runs: state.completed_runs,
      complete: state.complete,
      timeout: state.timeout,
      other: state.other
    }
  end

  defp increment_outcome(state, :complete), do: %{state | complete: state.complete + 1}
  defp increment_outcome(state, :timeout), do: %{state | timeout: state.timeout + 1}
  defp increment_outcome(state, _outcome), do: %{state | other: state.other + 1}
end
