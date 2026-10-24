Code.require_file("../host/multinode_model.ex", __DIR__)

alias RobotSim.MultinodeModel

peer_counts = [1, 2, 3, 8, 32]

IO.puts("multinode_model: fairness")

Enum.each(peer_counts, fn count ->
  {:ok, descriptors} = MultinodeModel.generate_descriptors(count)
  {:ok, result} = MultinodeModel.run(descriptors, 4, arrivals_per_round: 0)
  polls = Enum.map(result.peers, & &1.polls)

  IO.puts(
    "peers=#{count} rounds=4 polls_min=#{Enum.min(polls)} polls_max=#{Enum.max(polls)} " <>
      "elapsed_ms=#{result.elapsed_ms} max_active=#{result.max_active_transactions}"
  )
end)

{:ok, descriptors} = MultinodeModel.generate_descriptors(3)
slow_role = Enum.at(descriptors, 1).role

{:ok, slow} =
  MultinodeModel.run(descriptors, 3,
    arrivals_per_round: 0,
    service_ms: %{slow_role => 50}
  )

IO.puts(
  "multinode_model: slow peer=#{inspect(slow_role)} elapsed_ms=#{slow.elapsed_ms} " <>
    "polls=#{slow.peers |> Enum.map(& &1.polls) |> inspect()}"
)

{:ok, descriptors} = MultinodeModel.generate_descriptors(8)
failed_role = Enum.at(descriptors, 3).role

{:ok, failure} =
  MultinodeModel.run(descriptors, 4,
    failed_rounds: %{failed_role => :all},
    service_ms: %{failed_role => 2_000},
    queue_limit: 3
  )

failed = Enum.find(failure.peers, &(&1.descriptor.role == failed_role))
healthy = Enum.reject(failure.peers, &(&1.descriptor.role == failed_role))

IO.puts(
  "multinode_model: failure failed=#{inspect(failed_role)} failures=#{failed.failures} " <>
    "queue=#{failed.queue} rejected=#{failed.rejected} " <>
    "healthy_success_min=#{healthy |> Enum.map(& &1.successes) |> Enum.min()} " <>
    "elapsed_ms=#{failure.elapsed_ms}"
)

{:ok, descriptors} = MultinodeModel.generate_descriptors(3)

{:ok, overload} =
  MultinodeModel.run(descriptors, 4,
    arrivals_per_round: 2,
    drain_per_success: 1,
    queue_limit: 3
  )

overload_peer = hd(overload.peers)

IO.puts(
  "multinode_model: overload max_queue=#{overload_peer.max_queue} " <>
    "remaining=#{overload_peer.queue} rejected=#{overload_peer.rejected}"
)

{:ok, descriptors} = MultinodeModel.generate_descriptors(2)
recovering_role = Enum.at(descriptors, 1).role

{:ok, recovery} =
  MultinodeModel.run(descriptors, 4,
    failed_rounds: %{recovering_role => [1, 2]},
    session_change_rounds: %{recovering_role => [3]},
    queue_limit: 4
  )

recovered = Enum.find(recovery.peers, &(&1.descriptor.role == recovering_role))

IO.puts(
  "multinode_model: recovery session=#{recovered.session} " <>
    "stale_discarded=#{recovered.stale_discarded} delivered=#{recovered.delivered}"
)

{:ok, budgets} = MultinodeModel.resource_budgets(peer_counts)
IO.puts("multinode_model: resources")

Enum.each(budgets, fn budget ->
  IO.puts(
    "peers=#{budget.peer_count} configured_bytes=#{budget.configured_queue_payload_limit_bytes} " <>
      "configured_chunks=#{budget.configured_queue_chunk_limit} " <>
      "effective_bytes=#{budget.effective_queue_payload_limit_bytes} " <>
      "effective_chunks=#{budget.effective_queue_chunk_limit} " <>
      "observed_projection_bytes=#{budget.observed_queue_projection_bytes} " <>
      "exceeds_heap_watermark=#{budget.configured_limit_exceeds_baseline_heap_watermark}"
  )
end)
