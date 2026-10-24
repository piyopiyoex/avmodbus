defmodule RobotSim.MultinodeModel do
  @moduledoc """
  Host-only deterministic model for scaling the shared Modbus client beyond the
  two physical remote peers.

  This module does not emulate UART timing or AtomVM memory allocation. It
  models the invariants owned by this example: descriptor validation, one
  transaction at a time, round-robin service, bounded queues, peer failure,
  and session replacement.
  """

  @default_max_queued_bytes 8_192
  @default_max_queued_chunks 256
  @default_global_max_queued_bytes 8_192
  @default_global_max_queued_chunks 256
  @observed_min_free_heap_bytes 68_848
  @observed_queue_high_water_bytes_per_peer 279

  @type descriptor :: %{role: term(), unit_id: 1..247, node: term()}

  @doc "Generate symbolic peer descriptors without creating runtime atoms."
  @spec generate_descriptors(integer()) :: {:ok, [descriptor()]} | {:error, :invalid_peer_count}
  def generate_descriptors(count) when is_integer(count) and count >= 1 and count <= 247 do
    {:ok, generate_descriptors(1, count, [])}
  end

  def generate_descriptors(_count), do: {:error, :invalid_peer_count}

  @doc "Validate descriptor fields and uniqueness while preserving input order."
  @spec validate_descriptors(term()) :: {:ok, [descriptor()]} | {:error, term()}
  def validate_descriptors([]), do: {:error, :no_peers}

  def validate_descriptors(descriptors) when is_list(descriptors) do
    case validate_descriptors(descriptors, 1, [], [], []) do
      :ok -> {:ok, descriptors}
      {:error, _reason} = error -> error
    end
  end

  def validate_descriptors(_descriptors), do: {:error, :invalid_descriptors}

  @doc "Run a deterministic round-robin traffic model."
  @spec run([descriptor()], pos_integer(), keyword()) :: {:ok, map()} | {:error, term()}
  def run(descriptors, rounds, options \\ [])

  def run(descriptors, rounds, options)
      when is_integer(rounds) and rounds > 0 and is_list(options) do
    with {:ok, descriptors} <- validate_descriptors(descriptors),
         :ok <- validate_options(options) do
      queue_limit = Keyword.get(options, :queue_limit, 8)

      state = %{
        elapsed_ms: 0,
        peers: initial_peer_states(descriptors),
        trace: []
      }

      state = run_rounds(1, rounds, descriptors, queue_limit, options, state)

      {:ok,
       %{
         elapsed_ms: state.elapsed_ms,
         max_active_transactions: 1,
         peers: peer_results(descriptors, state.peers),
         trace: reverse(state.trace)
       }}
    end
  end

  def run(_descriptors, _rounds, _options), do: {:error, :invalid_rounds_or_options}

  @doc "Calculate queue limits and observed-scale projections for peer counts."
  @spec resource_budgets([pos_integer()], keyword()) :: {:ok, [map()]} | {:error, term()}
  def resource_budgets(peer_counts, options \\ [])

  def resource_budgets(peer_counts, options) when is_list(peer_counts) and is_list(options) do
    if Keyword.keyword?(options) do
      build_resource_budgets(peer_counts, options)
    else
      {:error, :invalid_options}
    end
  end

  def resource_budgets(peer_counts, _options) when is_list(peer_counts),
    do: {:error, :invalid_options}

  def resource_budgets(_peer_counts, _options), do: {:error, :invalid_peer_counts}

  defp build_resource_budgets(peer_counts, options) do
    max_queued_bytes = Keyword.get(options, :max_queued_bytes, @default_max_queued_bytes)
    max_queued_chunks = Keyword.get(options, :max_queued_chunks, @default_max_queued_chunks)

    global_max_queued_bytes =
      Keyword.get(options, :global_max_queued_bytes, @default_global_max_queued_bytes)

    global_max_queued_chunks =
      Keyword.get(options, :global_max_queued_chunks, @default_global_max_queued_chunks)

    cond do
      not positive_integer?(max_queued_bytes) ->
        {:error, {:invalid_option, :max_queued_bytes}}

      not positive_integer?(max_queued_chunks) ->
        {:error, {:invalid_option, :max_queued_chunks}}

      not positive_integer?(global_max_queued_bytes) ->
        {:error, {:invalid_option, :global_max_queued_bytes}}

      not positive_integer?(global_max_queued_chunks) ->
        {:error, {:invalid_option, :global_max_queued_chunks}}

      not all_peer_counts_valid?(peer_counts) ->
        {:error, :invalid_peer_counts}

      true ->
        {:ok,
         Enum.map(peer_counts, fn peer_count ->
           configured_bytes = peer_count * max_queued_bytes
           configured_chunks = peer_count * max_queued_chunks

           %{
             peer_count: peer_count,
             configured_queue_payload_limit_bytes: configured_bytes,
             configured_queue_chunk_limit: configured_chunks,
             global_queue_payload_limit_bytes: global_max_queued_bytes,
             global_queue_chunk_limit: global_max_queued_chunks,
             effective_queue_payload_limit_bytes: min(configured_bytes, global_max_queued_bytes),
             effective_queue_chunk_limit: min(configured_chunks, global_max_queued_chunks),
             observed_queue_projection_bytes:
               peer_count * @observed_queue_high_water_bytes_per_peer,
             baseline_min_free_heap_bytes: @observed_min_free_heap_bytes,
             configured_limit_exceeds_baseline_heap_watermark:
               configured_bytes >= @observed_min_free_heap_bytes,
             atomvm_heap_projection: :unknown
           }
         end)}
    end
  end

  defp generate_descriptors(index, count, acc) when index > count, do: reverse(acc)

  defp generate_descriptors(index, count, acc) do
    descriptor = %{
      role: {:peer, index},
      unit_id: index,
      node: {:peer, index, :modbus_local}
    }

    generate_descriptors(index + 1, count, [descriptor | acc])
  end

  defp validate_descriptors([], _index, _roles, _unit_ids, _nodes), do: :ok

  defp validate_descriptors(
         [%{role: role, unit_id: unit_id, node: node} | rest],
         index,
         roles,
         unit_ids,
         nodes
       ) do
    cond do
      role == nil ->
        {:error, {:invalid_descriptor, index, :invalid_role}}

      not is_integer(unit_id) or unit_id < 1 or unit_id > 247 ->
        {:error, {:invalid_descriptor, index, :invalid_unit_id}}

      node == nil ->
        {:error, {:invalid_descriptor, index, :invalid_node}}

      member?(roles, role) ->
        {:error, {:invalid_descriptor, index, :duplicate_role}}

      member?(unit_ids, unit_id) ->
        {:error, {:invalid_descriptor, index, :duplicate_unit_id}}

      member?(nodes, node) ->
        {:error, {:invalid_descriptor, index, :duplicate_node}}

      true ->
        validate_descriptors(
          rest,
          index + 1,
          [role | roles],
          [unit_id | unit_ids],
          [node | nodes]
        )
    end
  end

  defp validate_descriptors([_invalid | _rest], index, _roles, _unit_ids, _nodes),
    do: {:error, {:invalid_descriptor, index, :missing_fields}}

  defp validate_options(options) do
    if Keyword.keyword?(options) do
      validate_option_values(options)
    else
      {:error, :invalid_options}
    end
  end

  defp validate_option_values(options) do
    checks = [
      {:queue_limit, Keyword.get(options, :queue_limit, 8), &positive_integer?/1},
      {:arrivals_per_round, Keyword.get(options, :arrivals_per_round, 1), &profile?/1},
      {:drain_per_success, Keyword.get(options, :drain_per_success, 1), &profile?/1},
      {:service_ms, Keyword.get(options, :service_ms, 1), &profile?/1},
      {:failed_rounds, Keyword.get(options, :failed_rounds, %{}), &round_profile?/1},
      {:session_change_rounds, Keyword.get(options, :session_change_rounds, %{}),
       &round_profile?/1}
    ]

    validate_checks(checks)
  end

  defp validate_checks([]), do: :ok

  defp validate_checks([{key, value, predicate} | rest]) do
    if predicate.(value) do
      validate_checks(rest)
    else
      {:error, {:invalid_option, key}}
    end
  end

  defp profile?(value) when is_map(value) do
    Enum.all?(value, fn {_role, item} -> non_negative_integer?(item) end)
  end

  defp profile?(value), do: non_negative_integer?(value)

  defp round_profile?(value) when is_map(value) do
    Enum.all?(value, fn
      {_role, :all} -> true
      {_role, rounds} when is_list(rounds) -> Enum.all?(rounds, &positive_integer?/1)
      {_role, _rounds} -> false
    end)
  end

  defp round_profile?(_value), do: false

  defp initial_peer_states(descriptors) do
    Enum.reduce(descriptors, %{}, fn descriptor, acc ->
      Map.put(acc, descriptor.role, %{
        delivered: 0,
        descriptor: descriptor,
        failures: 0,
        max_queue: 0,
        polls: 0,
        queue: 0,
        rejected: 0,
        session: 1,
        stale_discarded: 0,
        successes: 0
      })
    end)
  end

  defp run_rounds(round, rounds, _descriptors, _queue_limit, _options, state)
       when round > rounds,
       do: state

  defp run_rounds(round, rounds, descriptors, queue_limit, options, state) do
    state = apply_session_changes(descriptors, round, options, state)
    state = enqueue_arrivals(descriptors, queue_limit, options, state)
    state = poll_peers(descriptors, round, options, state)
    run_rounds(round + 1, rounds, descriptors, queue_limit, options, state)
  end

  defp apply_session_changes([], _round, _options, state), do: state

  defp apply_session_changes([descriptor | rest], round, options, state) do
    changes = Keyword.get(options, :session_change_rounds, %{})
    peer = Map.get(state.peers, descriptor.role)

    peer =
      if round_selected?(changes, descriptor.role, round) do
        %{
          peer
          | queue: 0,
            session: peer.session + 1,
            stale_discarded: peer.stale_discarded + peer.queue
        }
      else
        peer
      end

    state = put_peer(state, descriptor.role, peer)
    apply_session_changes(rest, round, options, state)
  end

  defp enqueue_arrivals([], _queue_limit, _options, state), do: state

  defp enqueue_arrivals([descriptor | rest], queue_limit, options, state) do
    arrivals = profile_value(options, :arrivals_per_round, descriptor.role, 1)
    peer = Map.get(state.peers, descriptor.role)
    accepted = min(arrivals, queue_limit - peer.queue)
    rejected = arrivals - accepted
    queue = peer.queue + accepted

    peer = %{
      peer
      | max_queue: max(peer.max_queue, queue),
        queue: queue,
        rejected: peer.rejected + rejected
    }

    state = put_peer(state, descriptor.role, peer)
    enqueue_arrivals(rest, queue_limit, options, state)
  end

  defp poll_peers([], _round, _options, state), do: state

  defp poll_peers([descriptor | rest], round, options, state) do
    peer = Map.get(state.peers, descriptor.role)
    service_ms = profile_value(options, :service_ms, descriptor.role, 1)
    failed = round_selected?(Keyword.get(options, :failed_rounds, %{}), descriptor.role, round)
    drain = profile_value(options, :drain_per_success, descriptor.role, 1)
    delivered = if failed, do: 0, else: min(peer.queue, drain)
    started_at_ms = state.elapsed_ms
    finished_at_ms = started_at_ms + service_ms

    peer = %{
      peer
      | delivered: peer.delivered + delivered,
        failures: peer.failures + if(failed, do: 1, else: 0),
        polls: peer.polls + 1,
        queue: peer.queue - delivered,
        successes: peer.successes + if(failed, do: 0, else: 1)
    }

    event = %{
      delivered: delivered,
      finished_at_ms: finished_at_ms,
      outcome: if(failed, do: :failure, else: :success),
      peer: descriptor.role,
      queue_after: peer.queue,
      round: round,
      session: peer.session,
      started_at_ms: started_at_ms
    }

    state = %{
      state
      | elapsed_ms: finished_at_ms,
        peers: Map.put(state.peers, descriptor.role, peer),
        trace: [event | state.trace]
    }

    poll_peers(rest, round, options, state)
  end

  defp profile_value(options, key, role, default) do
    case Keyword.get(options, key, default) do
      value when is_integer(value) -> value
      values when is_map(values) -> Map.get(values, role, default)
    end
  end

  defp round_selected?(profile, role, round) do
    case Map.get(profile, role, []) do
      :all -> true
      rounds when is_list(rounds) -> member?(rounds, round)
      _other -> false
    end
  end

  defp peer_results(descriptors, peers) do
    Enum.map(descriptors, fn descriptor -> Map.get(peers, descriptor.role) end)
  end

  defp put_peer(state, role, peer), do: %{state | peers: Map.put(state.peers, role, peer)}

  defp all_peer_counts_valid?([]), do: false

  defp all_peer_counts_valid?([count | rest]) do
    positive_integer?(count) and count <= 247 and all_remaining_peer_counts_valid?(rest)
  end

  defp all_remaining_peer_counts_valid?([]), do: true

  defp all_remaining_peer_counts_valid?([count | rest]) do
    positive_integer?(count) and count <= 247 and all_remaining_peer_counts_valid?(rest)
  end

  defp positive_integer?(value), do: is_integer(value) and value > 0
  defp non_negative_integer?(value), do: is_integer(value) and value >= 0

  defp member?([], _value), do: false
  defp member?([value | _rest], value), do: true
  defp member?([_other | rest], value), do: member?(rest, value)

  defp reverse(list), do: reverse(list, [])
  defp reverse([], acc), do: acc
  defp reverse([item | rest], acc), do: reverse(rest, [item | acc])
end
