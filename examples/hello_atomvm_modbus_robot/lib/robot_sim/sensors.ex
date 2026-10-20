defmodule RobotSim.Sensors do
  @moduledoc """
  Deterministic virtual sensor process used by the multinode robot example.

  Each request returns the next distance and battery sample. The process is
  independent from the Modbus transport so the same message flow can be tested
  on the host and over distributed Erlang.
  """

  use GenServer

  @type sample :: %{
          sequence: pos_integer(),
          distance_mm: non_neg_integer(),
          battery_percent: 0..100
        }

  @doc "Start a virtual sensor process with optional `:name` and `:first_sequence` settings."
  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(options \\ []) do
    first_sequence = Keyword.get(options, :first_sequence, 1)

    case Keyword.get(options, :name) do
      nil -> GenServer.start_link(__MODULE__, first_sequence)
      name -> GenServer.start_link(__MODULE__, first_sequence, name: name)
    end
  end

  @doc "Build a deterministic sample for a positive sequence number."
  @spec build_sample(pos_integer()) :: sample()
  def build_sample(sequence) when is_integer(sequence) and sequence > 0 do
    %{
      sequence: sequence,
      distance_mm: 500 - rem(sequence - 1, 5) * 50,
      battery_percent: 100 - rem(sequence - 1, 10)
    }
  end

  @doc "Return whether a term is a valid virtual sensor sample."
  @spec valid_sample?(term()) :: boolean()
  def valid_sample?(%{
        sequence: sequence,
        distance_mm: distance_mm,
        battery_percent: battery_percent
      }) do
    is_integer(sequence) and sequence > 0 and is_integer(distance_mm) and distance_mm >= 0 and
      is_integer(battery_percent) and battery_percent >= 0 and battery_percent <= 100
  end

  def valid_sample?(_sample), do: false

  @doc "Read the next sample. Intended for local diagnostics and tests."
  @spec sample(GenServer.server()) :: sample()
  def sample(server), do: GenServer.call(server, :sample)

  @impl true
  def init(first_sequence) when is_integer(first_sequence) and first_sequence > 0,
    do: {:ok, %{next_sequence: first_sequence}}

  @impl true
  def handle_call(:sample, _from, state) do
    {sample, next_state} = next_sample(state)
    {:reply, sample, next_state}
  end

  # Explicit fallbacks avoid Elixir's generated callback path through
  # erlang:phash2/2, which AtomVM v0.7.0-beta.0 does not provide.
  def handle_call(message, _from, state), do: {:stop, {:bad_call, message}, state}

  @impl true
  def handle_cast(message, state), do: {:stop, {:bad_cast, message}, state}

  @impl true
  def handle_info({:sensor_request, reply_to, reference}, state) when is_pid(reply_to) do
    {sample, next_state} = next_sample(state)
    send(reply_to, {:sensor_reply, reference, node(), sample})
    {:noreply, next_state}
  end

  def handle_info(_message, state), do: {:noreply, state}

  defp next_sample(state) do
    sample = build_sample(state.next_sequence)
    {sample, %{state | next_sequence: state.next_sequence + 1}}
  end
end
