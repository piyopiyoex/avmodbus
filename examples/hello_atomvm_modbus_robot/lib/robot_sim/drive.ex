defmodule RobotSim.Drive do
  @moduledoc """
  Process that owns virtual rover state and executes idempotent command requests.

  Recent results are cached by request ID. Repeating the same request returns its
  cached result without applying the rover transition again. Guarded requests
  are rejected if they were prepared for another volatile Drive boot.
  """

  use GenServer

  alias DisterlProbe.Session
  alias RobotSim.{Protocol, Rover, Sensors}

  @default_max_completed 32

  @type state :: %{
          rover: Rover.t(),
          boot_id: Protocol.boot_id(),
          completed: [{Protocol.request_id(), Rover.command(), Protocol.result()}],
          max_completed: pos_integer(),
          trace: boolean(),
          drop_first_reply_per_request: boolean(),
          last_sensor_sample: nil | %{source_node: node(), sample: Sensors.sample()}
        }

  @doc "Start a drive process with optional state, naming, tracing, and reply fault-injection settings."
  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(options \\ []) do
    initial = Keyword.get(options, :initial, Rover.new())
    boot_id = Keyword.get(options, :boot_id, Session.new_id())
    max_completed = Keyword.get(options, :max_completed, @default_max_completed)
    trace = Keyword.get(options, :trace, false)

    drop_first_reply_per_request =
      Keyword.get(options, :drop_first_reply_per_request, false)

    case Keyword.get(options, :name) do
      nil ->
        GenServer.start_link(
          __MODULE__,
          {initial, boot_id, max_completed, trace, drop_first_reply_per_request}
        )

      name ->
        GenServer.start_link(
          __MODULE__,
          {initial, boot_id, max_completed, trace, drop_first_reply_per_request},
          name: name
        )
    end
  end

  @doc "Return the current rover state. Intended for local diagnostics and tests."
  @spec state(GenServer.server()) :: Rover.t()
  def state(server), do: GenServer.call(server, :state)

  @doc "Return the last sensor sample accepted through the Controller relay."
  @spec last_sensor_sample(GenServer.server()) ::
          nil | %{source_node: node(), sample: Sensors.sample()}
  def last_sensor_sample(server), do: GenServer.call(server, :last_sensor_sample)

  @impl true
  def init({%Rover{} = initial, boot_id, max_completed, trace, drop_first_reply_per_request})
      when is_integer(boot_id) and boot_id > 0 and is_integer(max_completed) and
             max_completed > 0 and is_boolean(trace) and
             is_boolean(drop_first_reply_per_request) do
    {:ok,
     %{
       rover: initial,
       boot_id: boot_id,
       completed: [],
       max_completed: max_completed,
       trace: trace,
       drop_first_reply_per_request: drop_first_reply_per_request,
       last_sensor_sample: nil
     }}
  end

  @impl true
  def handle_call(:state, _from, state), do: {:reply, state.rover, state}

  def handle_call(:last_sensor_sample, _from, state),
    do: {:reply, state.last_sensor_sample, state}

  # Explicit fallbacks avoid Elixir's generated callback path through
  # erlang:phash2/2, which AtomVM v0.7.0-beta.0 does not provide.
  def handle_call(message, _from, state), do: {:stop, {:bad_call, message}, state}

  @impl true
  def handle_cast(message, state), do: {:stop, {:bad_cast, message}, state}

  @impl true
  def handle_info({:drive_identity_request, reply_to, reference}, state)
      when is_pid(reply_to) and is_reference(reference) do
    send(reply_to, Protocol.identity_reply(reference, state.boot_id))
    {:noreply, state}
  end

  def handle_info({:robot_command, reply_to, request_id, command}, state)
      when is_pid(reply_to) and is_integer(request_id) and request_id >= 0 do
    handle_command(state, reply_to, request_id, command)
  end

  def handle_info(
        {:robot_guarded_command, reply_to, request_id, expected_boot_id, command},
        state
      )
      when is_pid(reply_to) and is_integer(request_id) and request_id >= 0 and
             is_integer(expected_boot_id) and expected_boot_id > 0 do
    if expected_boot_id == state.boot_id do
      handle_command(state, reply_to, request_id, command)
    else
      result = {:error, {:drive_boot_changed, state.boot_id}}
      trace(state, request_id, command, result)
      send(reply_to, Protocol.reply(request_id, result))
      {:noreply, state}
    end
  end

  def handle_info({:relayed_sensor_sample, reply_to, reference, source_node, sample}, state)
      when is_pid(reply_to) do
    if Sensors.valid_sample?(sample) do
      send(reply_to, {:sensor_sample_accepted, reference, node(), sample})
      {:noreply, %{state | last_sensor_sample: %{source_node: source_node, sample: sample}}}
    else
      send(reply_to, {:sensor_sample_rejected, reference, node(), :invalid_sample})
      {:noreply, state}
    end
  end

  def handle_info(_message, state), do: {:noreply, state}

  defp handle_command(state, reply_to, request_id, command) do
    {result, next_state, disposition} = execute_once(state, request_id, command)
    trace(state, request_id, command, result)
    reply_or_inject_loss(state, reply_to, request_id, result, disposition)
    {:noreply, next_state}
  end

  defp execute_once(state, request_id, command) do
    case find_completed(state.completed, request_id) do
      {^request_id, ^command, result} ->
        {result, state, :cached}

      {^request_id, _different_command, _result} ->
        {{:error, :request_id_conflict}, state, :conflict}

      nil ->
        result = Rover.execute(state.rover, command)
        rover = accepted_rover(result, state.rover)
        completed = remember(state.completed, {request_id, command, result}, state.max_completed)
        {result, %{state | rover: rover, completed: completed}, :executed}
    end
  end

  defp reply_or_inject_loss(
         %{drop_first_reply_per_request: true},
         _reply_to,
         request_id,
         _result,
         :executed
       ) do
    IO.puts("modbus_robot_drive: injected reply loss request_id=#{request_id}")
  end

  defp reply_or_inject_loss(_state, reply_to, request_id, result, _disposition) do
    send(reply_to, Protocol.reply(request_id, result))
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

  defp trace(%{trace: false}, _request_id, _command, _result), do: :ok

  defp trace(%{trace: true}, request_id, command, result) do
    IO.puts(
      "modbus_robot_drive: request_id=#{request_id} command=#{inspect(command)} result=#{inspect(result)}"
    )
  end
end
