defmodule RobotSim.MultinodeModelTest do
  use ExUnit.Case, async: true

  alias RobotSim.{MultinodeDistributed, MultinodeModel}

  @peer_counts [1, 2, 3, 8, 32]

  test "generates and validates arbitrary peer descriptors in input order" do
    Enum.each(@peer_counts, fn count ->
      assert {:ok, descriptors} = MultinodeModel.generate_descriptors(count)
      assert {:ok, ^descriptors} = MultinodeModel.validate_descriptors(descriptors)
      assert length(descriptors) == count
      assert Enum.map(descriptors, & &1.unit_id) == Enum.to_list(1..count)
    end)
  end

  test "accepts the two physical Controller peer descriptors" do
    descriptors = MultinodeDistributed.controller_peers()
    assert MultinodeModel.validate_descriptors(descriptors) == {:ok, descriptors}
  end

  test "rejects missing, invalid, and duplicate descriptor identities" do
    assert MultinodeModel.generate_descriptors(0) == {:error, :invalid_peer_count}
    assert MultinodeModel.generate_descriptors(248) == {:error, :invalid_peer_count}
    assert MultinodeModel.validate_descriptors([]) == {:error, :no_peers}

    assert MultinodeModel.validate_descriptors([%{role: :a, unit_id: 0, node: :a}]) ==
             {:error, {:invalid_descriptor, 1, :invalid_unit_id}}

    assert MultinodeModel.validate_descriptors([%{role: :a, unit_id: 1}]) ==
             {:error, {:invalid_descriptor, 1, :missing_fields}}

    assert MultinodeModel.validate_descriptors([
             %{role: :a, unit_id: 1, node: :a},
             %{role: :a, unit_id: 2, node: :b}
           ]) == {:error, {:invalid_descriptor, 2, :duplicate_role}}

    assert MultinodeModel.validate_descriptors([
             %{role: :a, unit_id: 1, node: :a},
             %{role: :b, unit_id: 1, node: :b}
           ]) == {:error, {:invalid_descriptor, 2, :duplicate_unit_id}}

    assert MultinodeModel.validate_descriptors([
             %{role: :a, unit_id: 1, node: :a},
             %{role: :b, unit_id: 2, node: :a}
           ]) == {:error, {:invalid_descriptor, 2, :duplicate_node}}
  end

  test "rejects invalid model bounds instead of running an ambiguous simulation" do
    {:ok, descriptors} = MultinodeModel.generate_descriptors(2)

    assert MultinodeModel.run(descriptors, 0) == {:error, :invalid_rounds_or_options}
    assert MultinodeModel.run(descriptors, 1, [:invalid]) == {:error, :invalid_options}

    assert MultinodeModel.run(descriptors, 1, queue_limit: 0) ==
             {:error, {:invalid_option, :queue_limit}}

    assert MultinodeModel.run(descriptors, 1, service_ms: %{hd(descriptors).role => -1}) ==
             {:error, {:invalid_option, :service_ms}}

    assert MultinodeModel.run(descriptors, 1, failed_rounds: %{hd(descriptors).role => [0]}) ==
             {:error, {:invalid_option, :failed_rounds}}
  end

  test "round-robin scheduling is deterministic and fair from one to 32 peers" do
    Enum.each(@peer_counts, fn count ->
      {:ok, descriptors} = MultinodeModel.generate_descriptors(count)
      assert {:ok, result} = MultinodeModel.run(descriptors, 4)

      expected_order =
        1..4
        |> Enum.flat_map(fn _round -> Enum.map(descriptors, & &1.role) end)

      assert Enum.map(result.trace, & &1.peer) == expected_order
      assert Enum.all?(result.peers, &(&1.polls == 4))
      assert Enum.all?(result.peers, &(&1.successes == 4))
      assert result.max_active_transactions == 1
      assert_serial_trace(result.trace)
    end)
  end

  test "a slow peer increases cycle time without changing poll fairness" do
    {:ok, descriptors} = MultinodeModel.generate_descriptors(3)
    slow_peer = Enum.at(descriptors, 1).role

    assert {:ok, result} =
             MultinodeModel.run(descriptors, 3,
               service_ms: %{slow_peer => 50},
               arrivals_per_round: 0
             )

    assert result.elapsed_ms == 3 * (1 + 50 + 1)
    assert Enum.all?(result.peers, &(&1.polls == 3))
    assert_serial_trace(result.trace)
  end

  test "a failed peer cannot starve healthy peers and its queue remains bounded" do
    {:ok, descriptors} = MultinodeModel.generate_descriptors(8)
    failed_peer = Enum.at(descriptors, 3).role

    assert {:ok, result} =
             MultinodeModel.run(descriptors, 4,
               failed_rounds: %{failed_peer => :all},
               service_ms: %{failed_peer => 2_000},
               queue_limit: 3
             )

    failed = peer_result(result, failed_peer)
    healthy = Enum.reject(result.peers, &(&1.descriptor.role == failed_peer))

    assert failed.failures == 4
    assert failed.queue == 3
    assert failed.max_queue == 3
    assert failed.rejected == 1
    assert Enum.all?(healthy, &(&1.successes == 4))
    assert Enum.all?(healthy, &(&1.delivered == 4))
    assert result.elapsed_ms == 4 * (7 + 2_000)
  end

  test "overload rejects excess arrivals instead of growing queues without a bound" do
    {:ok, descriptors} = MultinodeModel.generate_descriptors(3)

    assert {:ok, result} =
             MultinodeModel.run(descriptors, 4,
               arrivals_per_round: 2,
               drain_per_success: 1,
               queue_limit: 3
             )

    assert Enum.all?(result.peers, &(&1.max_queue == 3))
    assert Enum.all?(result.peers, &(&1.queue == 2))
    assert Enum.all?(result.peers, &(&1.rejected == 2))
    assert Enum.all?(result.peers, &(&1.delivered == 4))
  end

  test "session replacement discards stale queue and resumes in the new session" do
    {:ok, descriptors} = MultinodeModel.generate_descriptors(2)
    recovering_peer = Enum.at(descriptors, 1).role

    assert {:ok, result} =
             MultinodeModel.run(descriptors, 4,
               failed_rounds: %{recovering_peer => [1, 2]},
               session_change_rounds: %{recovering_peer => [3]},
               queue_limit: 4
             )

    recovered = peer_result(result, recovering_peer)
    recovered_trace = Enum.filter(result.trace, &(&1.peer == recovering_peer))

    assert recovered.failures == 2
    assert recovered.successes == 2
    assert recovered.session == 2
    assert recovered.stale_discarded == 2
    assert recovered.delivered == 2
    assert Enum.map(recovered_trace, & &1.session) == [1, 1, 2, 2]
  end

  test "resource budgets distinguish configured limits from observed projections" do
    assert {:ok, budgets} = MultinodeModel.resource_budgets(@peer_counts)

    assert Enum.map(budgets, & &1.configured_queue_payload_limit_bytes) ==
             [8_192, 16_384, 24_576, 65_536, 262_144]

    assert Enum.map(budgets, & &1.observed_queue_projection_bytes) ==
             [279, 558, 837, 2_232, 8_928]

    assert Enum.map(budgets, & &1.effective_queue_payload_limit_bytes) ==
             [8_192, 8_192, 8_192, 8_192, 8_192]

    assert Enum.map(budgets, & &1.effective_queue_chunk_limit) ==
             [256, 256, 256, 256, 256]

    refute Enum.at(budgets, 3).configured_limit_exceeds_baseline_heap_watermark
    assert Enum.at(budgets, 4).configured_limit_exceeds_baseline_heap_watermark
    assert Enum.all?(budgets, &(&1.atomvm_heap_projection == :unknown))
  end

  test "resource budgets reject invalid peer counts and options" do
    assert MultinodeModel.resource_budgets([]) == {:error, :invalid_peer_counts}
    assert MultinodeModel.resource_budgets([248]) == {:error, :invalid_peer_counts}
    assert MultinodeModel.resource_budgets([2], :invalid) == {:error, :invalid_options}
    assert MultinodeModel.resource_budgets([2], [:invalid]) == {:error, :invalid_options}

    assert MultinodeModel.resource_budgets([2], max_queued_bytes: 0) ==
             {:error, {:invalid_option, :max_queued_bytes}}

    assert MultinodeModel.resource_budgets([2], global_max_queued_bytes: 0) ==
             {:error, {:invalid_option, :global_max_queued_bytes}}

    assert MultinodeModel.resource_budgets([2], global_max_queued_chunks: 0) ==
             {:error, {:invalid_option, :global_max_queued_chunks}}
  end

  defp peer_result(result, role) do
    Enum.find(result.peers, &(&1.descriptor.role == role))
  end

  defp assert_serial_trace([_event]), do: :ok

  defp assert_serial_trace([event, next | rest]) do
    assert event.finished_at_ms == next.started_at_ms
    assert_serial_trace([next | rest])
  end
end
