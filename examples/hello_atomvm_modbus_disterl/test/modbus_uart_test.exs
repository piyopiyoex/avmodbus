defmodule DisterlProbe.ModbusUARTTest do
  use ExUnit.Case, async: true

  import ExUnit.CaptureIO

  alias AVModbus.Client

  alias DisterlProbe.{
    Channel,
    ModbusUART,
    Protocol,
    ResponseFault,
    ResponseTimeout,
    QueueBudget,
    TransactionStats
  }

  test "chunks and reassembles a 64 KiB stream despite repeated lost responses" do
    pattern = for byte <- 0..255, into: <<>>, do: <<byte>>
    payload = :binary.copy(pattern, 256)
    expected_chunks = div(byte_size(payload) + Protocol.max_payload() - 1, Protocol.max_payload())

    channel =
      Channel.new(100,
        max_queued_bytes: byte_size(payload),
        max_queued_chunks: expected_chunks
      )

    {:ok, sender} = ModbusUART.queue_chunks(channel, payload)

    {sender, receiver, reassembled, chunks, retries} =
      transfer(sender, Channel.new(200), <<>>, 0, 0)

    assert Channel.done?(sender)
    assert receiver.received == expected_chunks
    assert chunks == expected_chunks
    assert retries == div(expected_chunks, 7)
    assert reassembled == payload
  end

  test "an empty write queues no transport message" do
    channel = Channel.new()
    assert ModbusUART.queue_chunks(channel, <<>>) == {:ok, channel}
  end

  test "open reuses an explicitly prepared adapter" do
    assert ModbusUART.open(existing: self()) == self()
    assert ModbusUART.open(existing: :not_a_pid) == {:error, :invalid_existing_adapter}
  end

  test "a client adapter can use an externally owned managed client" do
    client = {Client, self()}

    options = [
      role: :client,
      client: client,
      serial: [],
      unit_id: 1,
      timeout_ms: 500,
      bulk_timeout_ms: 2_000,
      chunk_payload_bytes: 96,
      max_queued_bytes: 8_192,
      max_queued_chunks: 256,
      poll_ms: 20
    ]

    assert {:ok, state} = ModbusUART.init(options)
    assert state.resource == client
    refute state.owns_resource
    assert :ok = ModbusUART.terminate(:normal, state)
    assert_receive :poll
  end

  test "a client adapter preserves support for a raw client pid" do
    options = [
      role: :client,
      client: self(),
      serial: [],
      unit_id: 1,
      timeout_ms: 500,
      bulk_timeout_ms: 2_000,
      chunk_payload_bytes: 96,
      max_queued_bytes: 8_192,
      max_queued_chunks: 256,
      poll_ms: 20
    ]

    assert {:ok, state} = ModbusUART.init(options)
    assert state.resource == self()
    refute state.owns_resource
    assert :ok = ModbusUART.terminate(:normal, state)
    assert_receive :poll
  end

  test "a scheduled client waits for an external poll token" do
    options = [
      role: :client,
      client: self(),
      serial: [],
      unit_id: 1,
      timeout_ms: 500,
      bulk_timeout_ms: 2_000,
      chunk_payload_bytes: 96,
      max_queued_bytes: 8_192,
      max_queued_chunks: 256,
      poll_ms: 20,
      poll_scheduler: self()
    ]

    assert {:ok, state} = ModbusUART.init(options)
    assert state.poll_scheduler == self()
    refute_receive :poll
    assert :ok = ModbusUART.terminate(:normal, state)
  end

  test "a scheduled client returns the poll token after a timeout" do
    reference = make_ref()

    state =
      Channel.new()
      |> adapter_state()
      |> Map.merge(%{
        poll_scheduler: self(),
        poll_ms: 20,
        request_ref: reference,
        role: :client,
        stats: TransactionStats.start(TransactionStats.new(), 13, 0)
      })

    capture_io(fn ->
      assert {:noreply, next} =
               ModbusUART.handle_info({Client, reference, {:error, :timeout}}, state)

      assert next.request_ref == nil
    end)

    assert_receive {DisterlProbe.PollScheduler, :complete, adapter}
    assert adapter == self()
    refute_receive :poll
  end

  test "a client adapter rejects an invalid externally owned client" do
    options = [
      role: :client,
      client: :not_a_pid,
      serial: [],
      unit_id: 1,
      timeout_ms: 500,
      bulk_timeout_ms: 2_000,
      chunk_payload_bytes: 96,
      max_queued_bytes: 8_192,
      max_queued_chunks: 256,
      poll_ms: 20
    ]

    assert ModbusUART.init(options) == {:stop, {:error, :invalid_client}}

    assert ModbusUART.init(Keyword.put(options, :client, {Client, self(), :tcp})) ==
             {:stop, {:error, :invalid_client}}

    refute_receive :poll
  end

  test "peer readiness follows channel session observation" do
    state = adapter_state(Channel.new(100))
    assert {:reply, false, ^state} = ModbusUART.handle_call(:peer_ready, :unused_from, state)

    ready = put_in(state.channel.peer_session, 200)
    assert {:reply, true, ^ready} = ModbusUART.handle_call(:peer_ready, :unused_from, ready)
  end

  test "snapshots and resets bounded adapter metrics" do
    {:ok, channel} = Channel.queue(Channel.new(100), "abc")
    stats = TransactionStats.start(TransactionStats.new(), 13, 100)
    {stats, _event} = TransactionStats.succeed(stats, 20, 150)

    state = %{
      adapter_state(channel)
      | stats: stats,
        max_queued_bytes_observed: 7,
        max_outstanding_observed: 3
    }

    assert {:reply, snapshot, ^state} =
             ModbusUART.handle_call(:metrics_snapshot, :unused_from, state)

    assert snapshot.unit_id == 1
    assert snapshot.queued_bytes == 3
    assert snapshot.outstanding == 1
    assert snapshot.max_queued_bytes == 7
    assert snapshot.max_outstanding == 3
    assert snapshot.global_queue_budget == nil
    assert snapshot.transactions.successes == 1
    assert snapshot.transactions.average_elapsed_ms == 50
    assert snapshot.memory == nil

    assert {:reply, :ok, reset} =
             ModbusUART.handle_call(:reset_metrics, :unused_from, state)

    assert reset.max_queued_bytes_observed == 3
    assert reset.max_outstanding_observed == 1
    assert TransactionStats.summary(reset.stats).successes == 0
  end

  test "repeated idle sync markers share one unacknowledged outgoing chunk" do
    state = adapter_state(Channel.new(100))

    assert {:reply, :ok, queued} = callback({:write, <<0xAA, 0x55>>}, state)
    assert queued.channel.outstanding == 1
    assert queued.channel.queued_bytes == 2

    assert {:reply, :ok, coalesced} = callback({:write, <<0xAA, 0x55>>}, queued)
    assert coalesced == queued

    assert {:reply, :ok, distinct} = callback({:write, <<0xAA, 0x54>>}, coalesced)
    assert distinct.channel.outstanding == 2
    assert distinct.channel.queued_bytes == 4
  end

  test "repeated idle sync markers share one pending chunk" do
    state = adapter_state(Channel.new(100))

    assert {:reply, :ok, data_queued} = callback({:write, <<0x01, 0x02>>}, state)
    assert {:reply, :ok, sync_queued} = callback({:write, <<0xAA, 0x55>>}, data_queued)
    assert sync_queued.channel.outstanding == 2

    assert {:reply, :ok, coalesced} = callback({:write, <<0xAA, 0x55>>}, sync_queued)
    assert coalesced == sync_queued
    assert Channel.pending_payloads(coalesced.channel) == [<<0xAA, 0x55>>]
  end

  test "uses a configured payload size below the wire protocol maximum" do
    payload = :binary.copy(<<0xA5>>, 300)
    assert {:ok, channel} = ModbusUART.queue_chunks(Channel.new(300), payload, 96)

    assert {1, first} = channel.outgoing
    assert byte_size(first) == 96

    assert Enum.map(Channel.pending_payloads(channel), &byte_size/1) == [
             96,
             96,
             12
           ]
  end

  test "rejects a multi-chunk write atomically when it exceeds the byte bound" do
    channel = Channel.new(400, max_queued_bytes: 191, max_queued_chunks: 10)
    payload = :binary.copy(<<0x5A>>, 192)

    assert ModbusUART.queue_chunks(channel, payload, 96) == {:error, :queue_full}
    assert Channel.done?(channel)
    assert channel.queued_bytes == 0
  end

  test "the default byte bound accepts 8 KiB exactly and rejects one more byte" do
    payload = :binary.copy(<<0xA5>>, 8_192)

    assert {:ok, channel} = ModbusUART.queue_chunks(Channel.new(500), payload, 96)
    assert channel.queued_bytes == 8_192
    assert channel.outstanding == 86
    assert Channel.queue(channel, <<0>>) == {:error, :queue_full}
  end

  test "a successful multi-chunk write switches to the bulk response timeout" do
    payload = :binary.copy(<<0xA5>>, 192)
    state = adapter_state(Channel.new(max_queued_bytes: 1_024, max_queued_chunks: 16))

    assert {:reply, :ok, next} = callback({:write, payload}, state)
    assert next.channel.queued_bytes == 192
    assert next.channel.outstanding == 2
    assert ResponseTimeout.current(next.response_timeout) == 2_000
    assert next.trace_queue_active
  end

  test "a queue-full write rolls the session and resets the receive stream" do
    {:ok, channel} =
      Channel.new(max_queued_bytes: 191, max_queued_chunks: 16)
      |> Channel.queue(:binary.copy(<<0x11>>, 96))

    old_session = channel.session

    state =
      channel
      |> adapter_state()
      |> Map.put(:rx_buffer, "stale receive stream")
      |> Map.put(:trace_queue_active, true)
      |> Map.update!(:response_timeout, &ResponseTimeout.observe_write(&1, 192, 96))

    assert {:reply, {:error, :queue_full}, next} =
             callback({:write, :binary.copy(<<0x22>>, 192)}, state)

    refute next.channel.session == old_session
    assert next.channel.peer_session == nil
    assert next.channel.max_queued_bytes == 191
    assert next.channel.max_queued_chunks == 16
    assert Channel.done?(next.channel)
    assert next.channel.queued_bytes == 0
    assert next.rx_buffer == <<>>
    assert ResponseTimeout.current(next.response_timeout) == 500
    refute next.trace_queue_active
  end

  test "a shared budget rejects the whole write and releases this adapter queue" do
    {:ok, budget} = QueueBudget.start_link(max_queued_bytes: 100, max_queued_chunks: 2)
    other_adapter = spawn(fn -> receive do: (:stop -> :ok) end)
    assert :ok = QueueBudget.reserve(budget, other_adapter, 80, 1)

    state =
      Channel.new(450, max_queued_bytes: 1_024, max_queued_chunks: 16)
      |> adapter_state()
      |> Map.put(:queue_budget, budget)

    old_session = state.channel.session

    assert {:reply, {:error, :global_queue_full}, next} =
             callback({:write, :binary.copy(<<0x22>>, 96)}, state)

    refute next.channel.session == old_session
    assert Channel.done?(next.channel)

    assert %{
             queued_bytes: 80,
             queued_chunks: 1,
             active_owners: 1,
             rejected: 1
           } = QueueBudget.snapshot(budget)

    send(other_adapter, :stop)
  end

  test "an acknowledged chunk releases shared budget capacity" do
    {:ok, budget} = QueueBudget.start_link(max_queued_bytes: 100, max_queued_chunks: 4)
    {:ok, channel} = Channel.queue(Channel.new(460), "abc")
    assert :ok = QueueBudget.reserve(budget, self(), 3, 1)

    state =
      channel
      |> adapter_state()
      |> Map.merge(%{
        role: :server,
        queue_budget: budget,
        response_fault: ResponseFault.new()
      })

    {:ok, incoming} = Protocol.encode(560, 0, 460, 1, <<>>)
    assert {:reply, {:ok, _response}, next} = callback({:exchange, incoming}, state)
    assert next.channel.queued_bytes == 0
    assert %{queued_bytes: 0, queued_chunks: 0} = QueueBudget.snapshot(budget)
  end

  test "a peer session replacement releases stale shared budget capacity" do
    {:ok, budget} = QueueBudget.start_link(max_queued_bytes: 100, max_queued_chunks: 4)
    {:ok, channel} = Channel.queue(%{Channel.new(470) | peer_session: 570}, "stale")
    assert :ok = QueueBudget.reserve(budget, self(), 5, 1)

    state =
      channel
      |> adapter_state()
      |> Map.merge(%{
        role: :server,
        queue_budget: budget,
        response_fault: ResponseFault.new()
      })

    {:ok, incoming} = Protocol.encode(571, 0, 0, 0, <<>>)
    assert {:reply, {:ok, _response}, next} = callback({:exchange, incoming}, state)
    assert next.channel.peer_session == 571
    assert next.channel.queued_bytes == 0
    assert %{queued_bytes: 0, queued_chunks: 0} = QueueBudget.snapshot(budget)
  end

  test "adapter termination releases all shared budget capacity" do
    {:ok, budget} = QueueBudget.start_link(max_queued_bytes: 100, max_queued_chunks: 4)
    assert :ok = QueueBudget.reserve(budget, self(), 50, 2)

    state =
      Channel.new(480)
      |> adapter_state()
      |> Map.merge(%{queue_budget: budget, owns_resource: false})

    assert :ok = ModbusUART.terminate(:normal, state)

    assert %{queued_bytes: 0, queued_chunks: 0, active_owners: 0} =
             QueueBudget.snapshot(budget)
  end

  test "a new read closes and replaces a stale blocked reader" do
    first_tag = make_ref()
    second_tag = make_ref()
    state = adapter_state(Channel.new())

    assert {:noreply, state} =
             ModbusUART.handle_call({:read, :infinity}, {self(), first_tag}, state)

    assert {:noreply, next} =
             ModbusUART.handle_call({:read, :infinity}, {self(), second_tag}, state)

    assert_receive {^first_tag, {:error, :closed}}
    assert {{reader_pid, ^second_tag}, reference, nil, :infinity} = next.reader
    assert reader_pid == self()
    assert is_reference(reference)
    refute_receive {^second_tag, _reply}
  end

  test "a peer session change closes an established infinite reader" do
    reader_tag = make_ref()
    channel = %{Channel.new(100) | peer_session: 200}

    state =
      channel
      |> adapter_state()
      |> Map.put(:role, :server)
      |> Map.put(:reader, {{self(), reader_tag}, make_ref(), nil, :infinity})
      |> Map.put(:response_fault, ResponseFault.new())
      |> Map.put(:rx_buffer, "stale receive stream")
      |> Map.update!(:response_timeout, &ResponseTimeout.observe_write(&1, 192, 96))

    {:ok, incoming} = Protocol.encode(201, 0, 0, 0, <<>>)

    assert {:reply, {:ok, response}, next} = callback({:exchange, incoming}, state)
    assert_receive {^reader_tag, {:error, :closed}}

    assert next.channel.peer_session == 201
    assert next.reader == nil
    assert next.rx_buffer == <<>>
    assert ResponseTimeout.current(next.response_timeout) == 500

    assert {:ok, packet} = Protocol.decode(response)
    assert packet.session == 100
    assert packet.acknowledged_session == 201
  end

  defp transfer(sender, receiver, reassembled, chunks, retries) do
    {:ok, request} = packet(sender)
    {:ok, receiver, delivered} = Channel.receive_packet(receiver, request)
    reassembled = reassembled <> delivered
    chunks = chunks + 1

    {receiver, retries} =
      if rem(chunks, 7) == 0 do
        # Model a response that was lost after the server accepted the request.
        # The client retransmits the same packet, which must not be delivered twice.
        assert {:ok, duplicate_receiver, nil} = Channel.receive_packet(receiver, request)
        {duplicate_receiver, retries + 1}
      else
        {receiver, retries}
      end

    {:ok, acknowledgment} = packet(receiver)
    {:ok, sender, nil} = Channel.receive_packet(sender, acknowledgment)

    if Channel.done?(sender) do
      {sender, receiver, reassembled, chunks, retries}
    else
      transfer(sender, receiver, reassembled, chunks, retries)
    end
  end

  defp packet(channel) do
    with {:ok, binary} <- Channel.packet(channel), do: Protocol.decode(binary)
  end

  defp adapter_state(channel) do
    %{
      channel: channel,
      chunk_payload_bytes: 96,
      reader: nil,
      response_timeout: ResponseTimeout.new(500, 2_000),
      rx_buffer: <<>>,
      stats: TransactionStats.new(),
      trace_queue: false,
      trace_queue_active: false,
      queue_budget: nil,
      unit_id: 1,
      max_queued_bytes_observed: 0,
      max_outstanding_observed: 0
    }
  end

  defp callback(message, state) do
    caller = self()

    capture_io(fn ->
      send(caller, {:callback_result, ModbusUART.handle_call(message, :unused_from, state)})
    end)

    assert_receive {:callback_result, result}
    result
  end
end
