defmodule RobotSim.StartupRecoveryMatrix do
  @moduledoc """
  3台構成の起動順序と接続復旧を再現可能に記録するhost専用matrixです。

  実際のUART、RS485、AtomVM distributionをsimulationするものではありません。
  実機logから得た観測eventを、scenarioごとの必要条件、順序、blockerに照らして
  `:passed`、`:recovered_after_failure`、`:runtime_blocker`、`:incomplete`へ分類します。
  """

  alias RobotSim.ConnectionTrace

  @roles [:controller, :drive, :sensors]

  @startup_orders [
    {:startup_controller_drive_sensors, [:controller, :drive, :sensors]},
    {:startup_controller_sensors_drive, [:controller, :sensors, :drive]},
    {:startup_drive_controller_sensors, [:drive, :controller, :sensors]},
    {:startup_drive_sensors_controller, [:drive, :sensors, :controller]},
    {:startup_sensors_controller_drive, [:sensors, :controller, :drive]},
    {:startup_sensors_drive_controller, [:sensors, :drive, :controller]}
  ]

  @type role :: :controller | :drive | :sensors
  @type observation :: %{
          required(:event) => ConnectionTrace.event(),
          required(:role) => role(),
          required(:at_ms) => integer(),
          optional(atom()) => term()
        }

  @doc "起動順序、初回handshake失敗、接続後障害の全scenarioを返します。"
  @spec matrix() :: [map()]
  def matrix do
    startup_scenarios() ++ initial_failure_scenarios() ++ established_outage_scenarios()
  end

  @doc "IDでscenarioを取得します。"
  @spec fetch(atom()) :: {:ok, map()} | {:error, :unknown_scenario}
  def fetch(id) when is_atom(id) do
    case Enum.find(matrix(), &(&1.id == id)) do
      nil -> {:error, :unknown_scenario}
      scenario -> {:ok, scenario}
    end
  end

  @doc "実機または診断runの観測eventをscenarioの完了条件に照らして評価します。"
  @spec evaluate(atom(), [observation()]) :: {:ok, map()} | {:error, term()}
  def evaluate(id, observations) when is_atom(id) and is_list(observations) do
    with {:ok, scenario} <- fetch(id),
         :ok <- validate_observations(observations) do
      observed = Enum.map(observations, &event_key/1)
      missing = Enum.reject(scenario.required, &Enum.member?(observed, &1))
      ordering_violations = ordering_violations(scenario.ordered, observed)
      blocker = Enum.find(scenario.blockers, &Enum.member?(observed, &1))

      outcome = classify_outcome(missing, ordering_violations, blocker)
      fault_role_restarted = fault_role_restarted?(scenario, blocker, observed)

      {:ok,
       %{
         scenario: scenario.id,
         category: scenario.category,
         outcome: outcome,
         missing: missing,
         ordering_violations: ordering_violations,
         blocker: blocker,
         fault_role_restarted: fault_role_restarted,
         role_states: role_states(observations),
         observation_count: length(observations)
       }}
    end
  end

  def evaluate(_id, _observations), do: {:error, :invalid_observations}

  @doc "connection traceの1行からmatrix評価に必要なevent、role、時刻を取り出します。"
  @spec parse_line(String.t()) :: {:ok, observation()} | :ignore | {:error, term()}
  def parse_line(line) when is_binary(line) do
    case Regex.run(
           ~r/^modbus_robot_connection: at_ms=(-?\d+) event=([a-z_]+)(?: |$)/,
           String.trim(line)
         ) do
      [_, at_ms_text, event_text] ->
        parse_fields(line, at_ms_text, event_text)

      nil ->
        :ignore
    end
  end

  @doc "混在したconsole logからconnection traceだけを抽出してscenarioを評価します。"
  @spec evaluate_lines(atom(), Enumerable.t()) :: {:ok, map()} | {:error, term()}
  def evaluate_lines(id, lines) when is_atom(id) do
    with {:ok, observations} <- parse_lines(lines) do
      evaluate(id, observations)
    end
  end

  @doc "host testや手動記録で使う観測eventを作成します。"
  @spec observation(ConnectionTrace.event(), role(), integer(), map()) :: observation()
  def observation(event, role, at_ms, metadata \\ %{})
      when role in @roles and is_integer(at_ms) and is_map(metadata) do
    Map.merge(metadata, %{event: event, role: role, at_ms: at_ms})
  end

  defp parse_lines(lines) do
    Enum.reduce_while(lines, {:ok, []}, fn line, {:ok, observations} ->
      case parse_line(line) do
        {:ok, observation} -> {:cont, {:ok, [observation | observations]}}
        :ignore -> {:cont, {:ok, observations}}
        {:error, _reason} = error -> {:halt, error}
      end
    end)
    |> case do
      {:ok, observations} -> {:ok, Enum.reverse(observations)}
      {:error, _reason} = error -> error
    end
  end

  defp parse_fields(line, at_ms_text, event_text) do
    with {at_ms, ""} <- Integer.parse(at_ms_text),
         {:ok, event} <- find_atom(ConnectionTrace.events(), event_text),
         [_, role_text] <- Regex.run(~r/(?:^| )role=([a-z_]+)(?: |$)/, line),
         {:ok, role} <- find_atom(@roles, role_text) do
      {:ok, %{at_ms: at_ms, event: event, role: role}}
    else
      :error -> {:error, :invalid_timestamp}
      nil -> {:error, :missing_role}
      {:error, _reason} = error -> error
      _other -> {:error, :invalid_trace}
    end
  end

  defp find_atom(values, text) do
    case Enum.find(values, &(Atom.to_string(&1) == text)) do
      nil -> {:error, {:unknown_value, text}}
      value -> {:ok, value}
    end
  end

  defp startup_scenarios do
    Enum.map(@startup_orders, fn {id, boot_order} ->
      %{
        id: id,
        category: :startup_order,
        boot_order: boot_order,
        fault_role: nil,
        required: startup_required(),
        ordered: startup_order_constraints(boot_order),
        blockers: setup_blockers()
      }
    end)
  end

  defp initial_failure_scenarios do
    Enum.map([:drive, :sensors], fn role ->
      peer = other_remote(role)

      %{
        id: initial_failure_id(role),
        category: :initial_handshake_failure,
        boot_order: [role, :controller, peer],
        fault_role: role,
        required:
          [
            {:initial_connection_timeout, role},
            {:restart_started, role},
            {:restart_succeeded, role}
          ] ++ startup_required(),
        ordered:
          startup_order_constraints([role, :controller, peer]) ++
            [
              [
                {:initial_connection_timeout, role},
                {:restart_started, role},
                {:restart_succeeded, role},
                {:remote_connected, role}
              ]
            ],
        blockers: [
          {:initial_connection_timeout, role},
          {:distribution_start_failed, role},
          {:restart_failed, role},
          {:restart_budget_exhausted, role}
        ]
      }
    end)
  end

  defp established_outage_scenarios do
    Enum.map([:drive, :sensors], fn role ->
      peer = other_remote(role)

      %{
        id: established_outage_id(role),
        category: :established_connection_outage,
        boot_order: [:drive, :sensors, :controller],
        fault_role: role,
        required:
          startup_required() ++
            [
              {:stale_detected, role},
              {:restart_started, role},
              {:restart_succeeded, role},
              {:remote_reconnected, role},
              {:recovery_verified, role},
              {:peer_maintained, peer}
            ],
        ordered:
          startup_order_constraints([:drive, :sensors, :controller]) ++
            [
              [
                {:remote_connected, role},
                {:stale_detected, role},
                {:restart_started, role},
                {:restart_succeeded, role},
                {:remote_reconnected, role},
                {:recovery_verified, role}
              ]
            ],
        blockers: [
          {:restart_failed, role},
          {:recovery_verification_failed, role},
          {:recovery_verification_failed, peer}
        ]
      }
    end)
  end

  defp startup_required do
    Enum.map(@roles, &{:role_started, &1}) ++
      [
        {:carrier_peer_ready, :drive},
        {:carrier_peer_ready, :sensors},
        {:distribution_start_succeeded, :controller},
        {:distribution_start_succeeded, :drive},
        {:distribution_start_succeeded, :sensors},
        {:readiness_wait_started, :drive},
        {:readiness_wait_started, :sensors},
        {:readiness_acknowledged, :drive},
        {:readiness_acknowledged, :sensors},
        {:remote_connected, :drive},
        {:remote_connected, :sensors}
      ]
  end

  defp startup_order_constraints(boot_order) do
    boot_sequence = Enum.map(boot_order, &{:role_started, &1})

    [
      boot_sequence,
      [{:role_started, :controller}, {:distribution_start_succeeded, :controller}],
      [{:role_started, :drive}, {:distribution_start_succeeded, :drive}],
      [{:role_started, :sensors}, {:distribution_start_succeeded, :sensors}],
      [{:distribution_start_succeeded, :drive}, {:readiness_wait_started, :drive}],
      [{:distribution_start_succeeded, :sensors}, {:readiness_wait_started, :sensors}],
      [{:readiness_wait_started, :drive}, {:readiness_acknowledged, :drive}],
      [{:readiness_wait_started, :sensors}, {:readiness_acknowledged, :sensors}]
    ]
  end

  defp setup_blockers do
    [
      {:distribution_start_failed, :controller},
      {:distribution_start_failed, :drive},
      {:distribution_start_failed, :sensors}
    ]
  end

  defp initial_failure_id(:drive), do: :initial_handshake_timeout_drive
  defp initial_failure_id(:sensors), do: :initial_handshake_timeout_sensors

  defp established_outage_id(:drive), do: :established_outage_drive
  defp established_outage_id(:sensors), do: :established_outage_sensors

  defp other_remote(:drive), do: :sensors
  defp other_remote(:sensors), do: :drive

  defp validate_observations(observations) do
    Enum.reduce_while(observations, :ok, fn observation, :ok ->
      case validate_observation(observation) do
        :ok -> {:cont, :ok}
        {:error, _reason} = error -> {:halt, error}
      end
    end)
  end

  defp validate_observation(%{event: event, role: role, at_ms: at_ms})
       when role in @roles and is_integer(at_ms) do
    if event in ConnectionTrace.events() do
      :ok
    else
      {:error, {:invalid_event, event}}
    end
  end

  defp validate_observation(observation), do: {:error, {:invalid_observation, observation}}

  defp event_key(%{event: event, role: role}), do: {event, role}

  defp ordering_violations(constraints, observed) do
    Enum.reduce(constraints, [], fn sequence, violations ->
      case sequence_positions(sequence, observed) do
        {:ok, _positions} -> violations
        :missing -> violations
        {:error, positions} -> [%{sequence: sequence, positions: positions} | violations]
      end
    end)
    |> Enum.reverse()
  end

  defp sequence_positions(sequence, observed) do
    positions = Enum.map(sequence, &first_position(observed, &1))

    cond do
      Enum.any?(positions, &is_nil/1) ->
        :missing

      positions == Enum.sort(positions) and length(positions) == length(Enum.uniq(positions)) ->
        {:ok, positions}

      true ->
        {:error, positions}
    end
  end

  defp first_position(observed, key), do: Enum.find_index(observed, &(&1 == key))

  defp classify_outcome([], [], nil), do: :passed
  defp classify_outcome([], [], _blocker), do: :recovered_after_failure

  defp classify_outcome(_missing, _ordering_violations, blocker) when blocker != nil,
    do: :runtime_blocker

  defp classify_outcome(_missing, _ordering_violations, nil), do: :incomplete

  defp fault_role_restarted?(%{fault_role: nil}, _blocker, _observed), do: false
  defp fault_role_restarted?(_scenario, nil, _observed), do: false

  defp fault_role_restarted?(%{fault_role: role}, blocker, observed) do
    blocker_position = first_position(observed, blocker)

    observed
    |> Enum.drop(blocker_position + 1)
    |> Enum.member?({:role_started, role})
  end

  defp role_states(observations) do
    Enum.reduce(observations, initial_role_states(), fn observation, states ->
      Map.put(
        states,
        observation.role,
        next_role_state(observation.event, states[observation.role])
      )
    end)
  end

  defp initial_role_states, do: %{controller: :down, drive: :down, sensors: :down}

  defp next_role_state(:role_started, _state), do: :starting
  defp next_role_state(:carrier_peer_ready, _state), do: :carrier_ready
  defp next_role_state(:distribution_start_started, _state), do: :distribution_starting
  defp next_role_state(:distribution_start_succeeded, _state), do: :distribution_ready
  defp next_role_state(:distribution_start_failed, _state), do: :setup_failed
  defp next_role_state(:readiness_wait_started, _state), do: :awaiting_readiness
  defp next_role_state(:initial_connection_timeout, _state), do: :awaiting_recovery
  defp next_role_state(:readiness_acknowledged, _state), do: :connected
  defp next_role_state(:remote_connected, _state), do: :connected
  defp next_role_state(:remote_reconnected, _state), do: :connected
  defp next_role_state(:stale_detected, _state), do: :stale
  defp next_role_state(:restart_started, _state), do: :restarting
  defp next_role_state(:restart_succeeded, _state), do: :awaiting_readiness
  defp next_role_state(:restart_failed, _state), do: :restart_failed
  defp next_role_state(:restart_budget_exhausted, _state), do: :restart_exhausted
  defp next_role_state(:recovery_verified, _state), do: :connected
  defp next_role_state(:recovery_verification_failed, _state), do: :recovery_failed
  defp next_role_state(:peer_maintained, _state), do: :connected
end
