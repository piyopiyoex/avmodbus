defmodule RobotSim.Drive do
  @moduledoc """
  Process that owns virtual rover state and executes idempotent command requests.

  Recent results are cached by request ID. Repeating the same request returns its
  cached result without applying the rover transition again.
  """

  use GenServer

  alias RobotSim.{Protocol, Rover}

  @default_max_completed 32

  @type state :: %{
          rover: Rover.t(),
          completed: [{Protocol.request_id(), Rover.command(), Protocol.result()}],
          max_completed: pos_integer()
        }

  @doc "Start a drive process with optional `:initial`, `:max_completed`, and `:name` settings."
  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(options \\ []) do
    initial = Keyword.get(options, :initial, Rover.new())
    max_completed = Keyword.get(options, :max_completed, @default_max_completed)

    case Keyword.get(options, :name) do
      nil -> GenServer.start_link(__MODULE__, {initial, max_completed})
      name -> GenServer.start_link(__MODULE__, {initial, max_completed}, name: name)
    end
  end

  @doc "Return the current rover state. Intended for local diagnostics and tests."
  @spec state(GenServer.server()) :: Rover.t()
  def state(server), do: GenServer.call(server, :state)

  @impl true
  def init({%Rover{} = initial, max_completed})
      when is_integer(max_completed) and max_completed > 0 do
    {:ok, %{rover: initial, completed: [], max_completed: max_completed}}
  end

  @impl true
  def handle_call(:state, _from, state), do: {:reply, state.rover, state}

  # Explicit fallbacks avoid Elixir's generated callback path through
  # erlang:phash2/2, which AtomVM v0.7.0-beta.0 does not provide.
  def handle_call(message, _from, state), do: {:stop, {:bad_call, message}, state}

  @impl true
  def handle_cast(message, state), do: {:stop, {:bad_cast, message}, state}

  @impl true
  def handle_info({:robot_command, reply_to, request_id, command}, state)
      when is_pid(reply_to) and is_integer(request_id) and request_id >= 0 do
    {result, next_state} = execute_once(state, request_id, command)
    send(reply_to, Protocol.reply(request_id, result))
    {:noreply, next_state}
  end

  def handle_info(_message, state), do: {:noreply, state}

  defp execute_once(state, request_id, command) do
    case find_completed(state.completed, request_id) do
      {^request_id, ^command, result} ->
        {result, state}

      {^request_id, _different_command, _result} ->
        {{:error, :request_id_conflict}, state}

      nil ->
        result = Rover.execute(state.rover, command)
        rover = accepted_rover(result, state.rover)
        completed = remember(state.completed, {request_id, command, result}, state.max_completed)
        {result, %{state | rover: rover, completed: completed}}
    end
  end

  defp find_completed(completed, request_id) do
    find_completed_loop(completed, request_id)
  end

  defp find_completed_loop([], _request_id), do: nil

  defp find_completed_loop(
         [{request_id, _command, _result} = completed | _rest],
         request_id
       ),
       do: completed

  defp find_completed_loop([_completed | rest], request_id),
    do: find_completed_loop(rest, request_id)

  defp accepted_rover({:ok, %Rover{} = rover}, _current), do: rover
  defp accepted_rover({:error, _reason}, current), do: current

  defp remember(completed, entry, max_completed) do
    [entry | take(completed, max_completed - 1)]
  end

  defp take(_completed, 0), do: []
  defp take([], _remaining), do: []
  defp take([entry | rest], remaining), do: [entry | take(rest, remaining - 1)]
end
