defmodule RobotSim.ExchangeTrace do
  @moduledoc """
  FC-100 Serverのrequest受理とresponse処理を比較可能な形式で記録します。

  `response_returned`はAVModbus Serverへresponseを返したことを示します。Controllerが
  responseを受信したことは、Controller側のtransaction結果で別に確認します。
  """

  @events [:request_accepted, :response_returned, :response_dropped]

  @type event :: :request_accepted | :response_returned | :response_dropped

  @doc "記録可能なevent名を返します。"
  @spec events() :: [event()]
  def events, do: @events

  @doc "無効時は何もせず、有効時だけexchange eventを1行出力します。"
  @spec emit(boolean(), event(), integer(), keyword()) :: :ok
  def emit(false, _event, _at_ms, _fields), do: :ok

  def emit(true, event, at_ms, fields) do
    IO.puts(format(event, at_ms, fields))
    :ok
  end

  @doc "exchange eventをfield順が安定した1行のlogへ変換します。"
  @spec format(event(), integer(), keyword()) :: String.t()
  def format(event, at_ms, fields \\ [])

  def format(event, at_ms, fields)
      when event in @events and is_integer(at_ms) and is_list(fields) do
    unless Keyword.keyword?(fields) do
      raise ArgumentError, "exchange trace fields must be a keyword list"
    end

    suffix =
      Enum.reduce(fields, "", fn {key, value}, acc ->
        acc <> " #{key}=#{format_value(value)}"
      end)

    "modbus_robot_exchange: at_ms=#{at_ms} event=#{event}" <> suffix
  end

  def format(event, _at_ms, _fields) do
    raise ArgumentError, "unsupported exchange trace event: #{inspect(event)}"
  end

  defp format_value(value) when is_atom(value), do: Atom.to_string(value)
  defp format_value(value) when is_integer(value), do: Integer.to_string(value)
  defp format_value(value) when is_binary(value), do: inspect(value)
  defp format_value(value), do: inspect(value)
end
