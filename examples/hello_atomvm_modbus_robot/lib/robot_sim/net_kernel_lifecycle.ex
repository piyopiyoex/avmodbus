defmodule RobotSim.NetKernelLifecycle do
  @moduledoc """
  `net_kernel`の停止完了待ちと再開を、applicationの復旧判断から分離して実行します。

  callbackを差し替えられるため、AtomVM実機で観測した停止API失敗、登録解除timeout、
  再開失敗をhost testで個別に再現できます。
  """

  @compile {:no_warn_undefined, :net_kernel}

  @default_poll_ms 50
  @default_poll_attempts 40

  @type event ::
          :kernel_stop_requested
          | :kernel_stop_completed
          | :kernel_stop_failed
          | :kernel_start_started
          | :kernel_start_succeeded
          | :kernel_start_failed

  @doc "`net_kernel`を停止し、登録解除を確認してから`start_fun`で再開します。"
  @spec restart((-> :ok | {:error, term()}), keyword()) :: :ok | {:error, term()}
  def restart(start_fun, options \\ []) when is_function(start_fun, 0) and is_list(options) do
    stop_fun = Keyword.get(options, :stop_fun, &:net_kernel.stop/0)
    whereis_fun = Keyword.get(options, :whereis_fun, fn -> Process.whereis(:net_kernel) end)
    wait_fun = Keyword.get(options, :wait_fun, &wait/1)
    trace_fun = Keyword.get(options, :trace_fun, fn _event, _fields -> :ok end)
    poll_ms = Keyword.get(options, :poll_ms, @default_poll_ms)
    poll_attempts = Keyword.get(options, :poll_attempts, @default_poll_attempts)

    trace_fun.(:kernel_stop_requested, [])

    case stop_fun.() do
      :ok ->
        await_stop(
          start_fun,
          whereis_fun,
          wait_fun,
          trace_fun,
          poll_ms,
          poll_attempts
        )

      other ->
        failed(trace_fun, :kernel_stop_failed, {:net_kernel_stop_failed, other})
    end
  end

  defp await_stop(start_fun, whereis_fun, wait_fun, trace_fun, poll_ms, attempts_left)
       when attempts_left > 0 do
    case whereis_fun.() do
      nil ->
        trace_fun.(:kernel_stop_completed, [])
        trace_fun.(:kernel_start_started, [])

        case start_fun.() do
          :ok ->
            trace_fun.(:kernel_start_succeeded, [])
            :ok

          {:error, reason} = error ->
            trace_fun.(:kernel_start_failed, reason: reason)
            error
        end

      _pid ->
        wait_fun.(poll_ms)

        await_stop(
          start_fun,
          whereis_fun,
          wait_fun,
          trace_fun,
          poll_ms,
          attempts_left - 1
        )
    end
  end

  defp await_stop(_start_fun, whereis_fun, _wait_fun, trace_fun, _poll_ms, 0) do
    failed(trace_fun, :kernel_stop_failed, {:net_kernel_stop_timeout, whereis_fun.()})
  end

  defp failed(trace_fun, event, reason) do
    trace_fun.(event, reason: reason)
    {:error, reason}
  end

  defp wait(milliseconds) do
    receive do
    after
      milliseconds -> :ok
    end
  end
end
