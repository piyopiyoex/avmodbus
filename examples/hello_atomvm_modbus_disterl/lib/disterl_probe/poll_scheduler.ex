defmodule DisterlProbe.PollScheduler do
  @moduledoc """
  Round-robin scheduler for logical Modbus UART adapters sharing one client.

  Only one adapter receives the `:poll` token at a time. The adapter returns
  the token after its transaction completes, so an unavailable Unit cannot
  consume another Unit's request deadline while both requests wait in the
  managed-client queue.
  """

  use GenServer

  @doc "Start a paused scheduler."
  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(options \\ []) when is_list(options),
    do: GenServer.start_link(__MODULE__, options)

  @doc "Register an adapter before polling starts."
  @spec register(pid(), pid()) :: :ok | {:error, :already_registered | :already_started}
  def register(scheduler, adapter) when is_pid(scheduler) and is_pid(adapter),
    do: GenServer.call(scheduler, {:register, adapter})

  @doc "Start dispatching the poll token."
  @spec start(pid()) :: :ok | {:error, :already_started | :no_adapters}
  def start(scheduler) when is_pid(scheduler), do: GenServer.call(scheduler, :start)

  @doc false
  @spec complete(pid(), pid()) :: :ok
  def complete(scheduler, adapter) when is_pid(scheduler) and is_pid(adapter) do
    send(scheduler, {__MODULE__, :complete, adapter})
    :ok
  end

  @impl true
  def init(options) do
    delay_ms = Keyword.get(options, :delay_ms, 0)

    if is_integer(delay_ms) and delay_ms >= 0 do
      {:ok, %{delay_ms: delay_ms, started: false, current: nil, adapters: []}}
    else
      {:stop, :invalid_delay}
    end
  end

  @impl true
  def handle_call({:register, _adapter}, _from, %{started: true} = state),
    do: {:reply, {:error, :already_started}, state}

  def handle_call({:register, adapter}, _from, state) do
    if member?(state.adapters, adapter) do
      {:reply, {:error, :already_registered}, state}
    else
      {:reply, :ok, %{state | adapters: state.adapters ++ [adapter]}}
    end
  end

  def handle_call(:start, _from, %{started: true} = state),
    do: {:reply, {:error, :already_started}, state}

  def handle_call(:start, _from, %{adapters: []} = state),
    do: {:reply, {:error, :no_adapters}, state}

  def handle_call(:start, _from, state) do
    next = dispatch(%{state | started: true})
    {:reply, :ok, next}
  end

  @impl true
  def handle_info({__MODULE__, :complete, adapter}, %{current: adapter} = state) do
    Process.send_after(self(), :dispatch, state.delay_ms)
    {:noreply, %{state | current: nil, adapters: state.adapters ++ [adapter]}}
  end

  def handle_info(:dispatch, %{started: true, current: nil} = state),
    do: {:noreply, dispatch(state)}

  def handle_info(_message, state), do: {:noreply, state}

  defp dispatch(%{adapters: [adapter | rest]} = state) do
    send(adapter, :poll)
    %{state | current: adapter, adapters: rest}
  end

  defp dispatch(state), do: state

  defp member?([], _adapter), do: false
  defp member?([adapter | _rest], adapter), do: true
  defp member?([_other | rest], adapter), do: member?(rest, adapter)
end
