defmodule RobotSim.RemoteHealth do
  @moduledoc """
  Pure state machine for remote-side readiness ACK health.

  The detector is scoped to one board boot. It distinguishes distribution
  connection generations, ignores stale ACKs, and bounds automatic restart
  requests so a broken link cannot cause an unbounded restart loop.
  """

  @type t :: %{
          enabled: boolean(),
          connection_id: pos_integer(),
          last_ack_ms: integer(),
          ack_timeout_ms: pos_integer(),
          max_restarts: non_neg_integer(),
          restarts: non_neg_integer(),
          exhaustion_reported: boolean()
        }

  @doc "Create detector state for a new board boot and distribution connection."
  @spec new(pos_integer(), integer(), keyword()) :: t()
  def new(connection_id, now_ms, options \\ [])
      when is_integer(connection_id) and connection_id > 0 and is_integer(now_ms) do
    %{
      enabled: Keyword.get(options, :enabled, false),
      connection_id: connection_id,
      last_ack_ms: now_ms,
      ack_timeout_ms: Keyword.get(options, :ack_timeout_ms, 90_000),
      max_restarts: Keyword.get(options, :max_restarts, 1),
      restarts: 0,
      exhaustion_reported: false
    }
  end

  @doc "Record an ACK only when it belongs to the current connection generation."
  @spec acknowledge(t(), pos_integer(), integer()) :: t()
  def acknowledge(%{connection_id: connection_id} = state, connection_id, now_ms)
      when is_integer(now_ms) do
    %{state | last_ack_ms: now_ms, exhaustion_reported: false}
  end

  def acknowledge(state, _stale_connection_id, _now_ms), do: state

  @doc "Evaluate whether the current connection should be restarted."
  @spec evaluate(t(), integer()) ::
          {:healthy | :disabled | :restart | :exhausted | :waiting, t()}
  def evaluate(%{enabled: false} = state, _now_ms), do: {:disabled, state}

  def evaluate(state, now_ms) when is_integer(now_ms) do
    if now_ms - state.last_ack_ms > state.ack_timeout_ms do
      evaluate_overdue(state, now_ms)
    else
      {:healthy, state}
    end
  end

  @doc "Move detector state to a newly opened distribution connection."
  @spec reconnected(t(), pos_integer(), integer()) :: t()
  def reconnected(state, connection_id, now_ms)
      when is_integer(connection_id) and connection_id > 0 and is_integer(now_ms) do
    %{
      state
      | connection_id: connection_id,
        last_ack_ms: now_ms,
        exhaustion_reported: false
    }
  end

  defp evaluate_overdue(%{restarts: restarts, max_restarts: max_restarts} = state, now_ms)
       when restarts < max_restarts do
    {:restart,
     %{
       state
       | restarts: restarts + 1,
         last_ack_ms: now_ms,
         exhaustion_reported: false
     }}
  end

  defp evaluate_overdue(%{exhaustion_reported: false} = state, _now_ms),
    do: {:exhausted, %{state | exhaustion_reported: true}}

  defp evaluate_overdue(state, _now_ms), do: {:waiting, state}
end
