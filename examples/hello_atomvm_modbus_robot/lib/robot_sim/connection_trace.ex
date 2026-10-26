defmodule RobotSim.ConnectionTrace do
  @moduledoc """
  分散接続の初期化・切断・復旧を同じ形式で記録するための補助moduleです。

  通常動作では無効にし、startup / recovery test matrixを実行するときだけ有効にします。
  event名とfield名はlogを比較しやすくするための機械可読な識別子として英語のまま保持します。
  """

  @events [
    :role_started,
    :carrier_wait_started,
    :carrier_peer_ready,
    :distribution_start_started,
    :distribution_start_succeeded,
    :distribution_start_failed,
    :readiness_wait_started,
    :initial_connection_timeout,
    :readiness_acknowledged,
    :remote_connected,
    :remote_reconnected,
    :stale_detected,
    :restart_deferred,
    :transport_resumed,
    :transport_ready,
    :restart_started,
    :kernel_stop_requested,
    :kernel_stop_completed,
    :kernel_stop_failed,
    :kernel_start_started,
    :kernel_start_succeeded,
    :kernel_start_failed,
    :restart_succeeded,
    :restart_failed,
    :restart_budget_exhausted,
    :recovery_verified,
    :recovery_verification_failed,
    :peer_maintained
  ]

  @type event ::
          :role_started
          | :carrier_wait_started
          | :carrier_peer_ready
          | :distribution_start_started
          | :distribution_start_succeeded
          | :distribution_start_failed
          | :readiness_wait_started
          | :initial_connection_timeout
          | :readiness_acknowledged
          | :remote_connected
          | :remote_reconnected
          | :stale_detected
          | :restart_deferred
          | :transport_resumed
          | :transport_ready
          | :restart_started
          | :kernel_stop_requested
          | :kernel_stop_completed
          | :kernel_stop_failed
          | :kernel_start_started
          | :kernel_start_succeeded
          | :kernel_start_failed
          | :restart_succeeded
          | :restart_failed
          | :restart_budget_exhausted
          | :recovery_verified
          | :recovery_verification_failed
          | :peer_maintained

  @doc "記録可能なevent名を返します。"
  @spec events() :: [event()]
  def events, do: @events

  @doc "無効時は何もせず、有効時だけconnection eventを1行出力します。"
  @spec emit(boolean(), event(), integer(), keyword()) :: :ok
  def emit(false, _event, _at_ms, _fields), do: :ok

  def emit(true, event, at_ms, fields) do
    IO.puts(format(event, at_ms, fields))
    :ok
  end

  @doc "connection eventをfield順が安定した1行のlogへ変換します。"
  @spec format(event(), integer(), keyword()) :: String.t()
  def format(event, at_ms, fields \\ [])

  def format(event, at_ms, fields)
      when event in @events and is_integer(at_ms) and is_list(fields) do
    unless Keyword.keyword?(fields) do
      raise ArgumentError, "connection trace fields must be a keyword list"
    end

    suffix =
      Enum.reduce(fields, "", fn {key, value}, acc ->
        acc <> " #{key}=#{format_value(value)}"
      end)

    "modbus_robot_connection: at_ms=#{at_ms} event=#{event}" <> suffix
  end

  def format(event, _at_ms, _fields) do
    raise ArgumentError, "unsupported connection trace event: #{inspect(event)}"
  end

  defp format_value(value) when is_atom(value), do: Atom.to_string(value)
  defp format_value(value) when is_integer(value), do: Integer.to_string(value)
  defp format_value(value) when is_binary(value), do: inspect(value)
  defp format_value(value), do: inspect(value)
end
