import Config

parse_integer = fn name, default ->
  case Integer.parse(System.get_env(name) || "") do
    {value, ""} -> value
    _ -> default
  end
end

parse_boolean = fn name, default ->
  case System.get_env(name) do
    nil ->
      default

    value when value in ["1", "true"] ->
      true

    value when value in ["0", "false"] ->
      false

    value ->
      raise ArgumentError, "#{name} must be one of 1, true, 0, or false; got #{inspect(value)}"
  end
end

mode =
  case System.get_env("ROBOT_MODE") do
    nil ->
      :distributed

    "distributed" ->
      :distributed

    "multidrop" ->
      :multidrop

    "multinode" ->
      :multinode

    value ->
      raise ArgumentError,
            "ROBOT_MODE must be distributed, multidrop, or multinode; got #{inspect(value)}"
  end

role =
  case System.get_env("ROBOT_ROLE") do
    nil ->
      :controller

    "controller" ->
      :controller

    "drive" ->
      :drive

    "sensors" ->
      :sensors

    value ->
      raise ArgumentError,
            "ROBOT_ROLE must be controller, drive, or sensors; got #{inspect(value)}"
  end

transport_role = if role == :controller, do: :client, else: :server
distributed_role = if role == :drive, do: :drive, else: :controller
default_unit_id = if role == :sensors, do: 2, else: 1
unit_id = parse_integer.("MODBUS_UNIT_ID", default_unit_id)
drive_unit_id = parse_integer.("ROBOT_DRIVE_UNIT_ID", 1)
sensors_unit_id = parse_integer.("ROBOT_SENSORS_UNIT_ID", 2)
multidrop_cycles = parse_integer.("ROBOT_MULTIDROP_CYCLES", 3)
multidrop_interval_ms = parse_integer.("ROBOT_MULTIDROP_INTERVAL_MS", 1_000)
multidrop_start_delay_ms = parse_integer.("ROBOT_MULTIDROP_START_DELAY_MS", 2_000)
multidrop_gap_ms = parse_integer.("ROBOT_MULTIDROP_GAP_MS", 20)
chunk_payload_bytes = parse_integer.("MODBUS_CHUNK_PAYLOAD_BYTES", 96)
max_queued_bytes = parse_integer.("MODBUS_MAX_QUEUED_BYTES", 8_192)
max_queued_chunks = parse_integer.("MODBUS_MAX_QUEUED_CHUNKS", 256)

multinode_global_max_queued_bytes =
  parse_integer.("ROBOT_MULTINODE_GLOBAL_MAX_QUEUED_BYTES", 8_192)

multinode_global_max_queued_chunks =
  parse_integer.("ROBOT_MULTINODE_GLOBAL_MAX_QUEUED_CHUNKS", 256)

fault_drop_responses = parse_integer.("MODBUS_FAULT_DROP_RESPONSES", 0)
fault_min_payload_bytes = parse_integer.("MODBUS_FAULT_MIN_PAYLOAD_BYTES", 96)
fault_after_ms = parse_integer.("MODBUS_FAULT_AFTER_MS", 10_000)
fault_rearm_on_restart = parse_boolean.("MODBUS_FAULT_REARM_ON_RESTART", false)
mission_timeout_ms = parse_integer.("ROBOT_COMMAND_TIMEOUT_MS", 60_000)
mission_retries = parse_integer.("ROBOT_COMMAND_RETRIES", 1)
mission_start_delay_ms = parse_integer.("ROBOT_MISSION_START_DELAY_MS", 2_000)
multinode_announce_ms = parse_integer.("ROBOT_MULTINODE_ANNOUNCE_MS", 30_000)
multinode_health_check_ms = parse_integer.("ROBOT_MULTINODE_HEALTH_CHECK_MS", 5_000)
multinode_lease_ms = parse_integer.("ROBOT_MULTINODE_LEASE_MS", 75_000)
multinode_soak_cycles = parse_integer.("ROBOT_MULTINODE_SOAK_CYCLES", 0)
multinode_soak_payload_bytes = parse_integer.("ROBOT_MULTINODE_SOAK_PAYLOAD_BYTES", 128)
multinode_soak_interval_ms = parse_integer.("ROBOT_MULTINODE_SOAK_INTERVAL_MS", 250)
multinode_soak_retries = parse_integer.("ROBOT_MULTINODE_SOAK_RETRIES", 1)
multinode_traffic_samples = parse_integer.("ROBOT_MULTINODE_TRAFFIC_SAMPLES", 0)
multinode_traffic_runs = parse_integer.("ROBOT_MULTINODE_TRAFFIC_RUNS", 1)
multinode_traffic_idle_ms = parse_integer.("ROBOT_MULTINODE_TRAFFIC_IDLE_MS", 0)
multinode_metrics_interval_ms = parse_integer.("ROBOT_MULTINODE_METRICS_INTERVAL_MS", 0)

multinode_traffic_drive_interval_ms =
  parse_integer.("ROBOT_MULTINODE_TRAFFIC_DRIVE_INTERVAL_MS", 2_000)

multinode_traffic_sensors_interval_ms =
  parse_integer.("ROBOT_MULTINODE_TRAFFIC_SENSORS_INTERVAL_MS", 1_000)

multinode_traffic_payload_bytes = parse_integer.("ROBOT_MULTINODE_TRAFFIC_PAYLOAD_BYTES", 16)
multinode_traffic_timeout_ms = parse_integer.("ROBOT_MULTINODE_TRAFFIC_TIMEOUT_MS", 120_000)
multinode_traffic_settle_ms = parse_integer.("ROBOT_MULTINODE_TRAFFIC_SETTLE_MS", 30_000)

multinode_traffic_start_delay_ms =
  parse_integer.("ROBOT_MULTINODE_TRAFFIC_START_DELAY_MS", 0)

multinode_traffic_ack_timeout_ms =
  parse_integer.("ROBOT_MULTINODE_TRAFFIC_ACK_TIMEOUT_MS", 90_000)

multinode_traffic_ack_retries = parse_integer.("ROBOT_MULTINODE_TRAFFIC_ACK_RETRIES", 1)

multinode_restart_on_traffic_ack_timeout =
  parse_boolean.("ROBOT_MULTINODE_RESTART_ON_TRAFFIC_ACK_TIMEOUT", false)

multinode_remote_health_enabled =
  parse_boolean.("ROBOT_MULTINODE_REMOTE_HEALTH_ENABLED", false)

multinode_remote_health_trace =
  parse_boolean.("ROBOT_MULTINODE_REMOTE_HEALTH_TRACE", false)

multinode_defer_restart_until_transport_ready =
  parse_boolean.("ROBOT_MULTINODE_DEFER_RESTART_UNTIL_TRANSPORT_READY", false)

multinode_transport_activity_trace =
  parse_boolean.("ROBOT_MULTINODE_TRANSPORT_ACTIVITY_TRACE", false)

multinode_exchange_trace =
  parse_boolean.("ROBOT_MULTINODE_EXCHANGE_TRACE", false)

multinode_transport_ready_confirmations =
  parse_integer.("ROBOT_MULTINODE_TRANSPORT_READY_CONFIRMATIONS", 2)

multinode_connection_trace =
  parse_boolean.("ROBOT_MULTINODE_CONNECTION_TRACE", false)

multinode_initial_recovery_enabled =
  parse_boolean.("ROBOT_MULTINODE_INITIAL_RECOVERY_ENABLED", true)

multinode_remote_ack_timeout_ms =
  parse_integer.("ROBOT_MULTINODE_REMOTE_ACK_TIMEOUT_MS", 90_000)

multinode_remote_max_restarts =
  parse_integer.("ROBOT_MULTINODE_REMOTE_MAX_RESTARTS", 1)

multinode_lifecycle_probe_after_ms =
  parse_integer.("ROBOT_MULTINODE_LIFECYCLE_PROBE_AFTER_MS", 0)

multinode_application_recovery_probe_enabled =
  parse_boolean.("ROBOT_MULTINODE_APPLICATION_RECOVERY_PROBE_ENABLED", false)

sensor_mission_steps = parse_integer.("ROBOT_SENSOR_MISSION_STEPS", 3)
sensor_mission_step_delay_ms = parse_integer.("ROBOT_SENSOR_MISSION_STEP_DELAY_MS", 0)

drive_drop_first_reply_per_request =
  parse_boolean.("ROBOT_DRIVE_DROP_FIRST_REPLY_PER_REQUEST", false)

wait_for_peer = parse_boolean.("MODBUS_WAIT_FOR_PEER", role == :controller)

if mode == :distributed and role == :sensors do
  raise ArgumentError, "ROBOT_ROLE=sensors is not supported with ROBOT_MODE=distributed"
end

if unit_id < 1 or unit_id > 247 do
  raise ArgumentError, "MODBUS_UNIT_ID must be between 1 and 247"
end

if drive_unit_id < 1 or drive_unit_id > 247 or sensors_unit_id < 1 or sensors_unit_id > 247 do
  raise ArgumentError, "ROBOT_DRIVE_UNIT_ID and ROBOT_SENSORS_UNIT_ID must be between 1 and 247"
end

if drive_unit_id == sensors_unit_id do
  raise ArgumentError, "ROBOT_DRIVE_UNIT_ID and ROBOT_SENSORS_UNIT_ID must be different"
end

if multidrop_cycles < 1 do
  raise ArgumentError, "ROBOT_MULTIDROP_CYCLES must be a positive integer"
end

if multidrop_interval_ms < 0 or multidrop_start_delay_ms < 0 or multidrop_gap_ms < 0 do
  raise ArgumentError, "multidrop timing values must be non-negative integers"
end

if chunk_payload_bytes < 1 or chunk_payload_bytes > 232 do
  raise ArgumentError, "MODBUS_CHUNK_PAYLOAD_BYTES must be between 1 and 232"
end

if max_queued_bytes < 1 do
  raise ArgumentError, "MODBUS_MAX_QUEUED_BYTES must be a positive integer"
end

if max_queued_chunks < 1 or max_queued_chunks > 65_535 do
  raise ArgumentError, "MODBUS_MAX_QUEUED_CHUNKS must be between 1 and 65535"
end

if multinode_global_max_queued_bytes < 1 do
  raise ArgumentError, "ROBOT_MULTINODE_GLOBAL_MAX_QUEUED_BYTES must be a positive integer"
end

if multinode_global_max_queued_chunks < 1 do
  raise ArgumentError, "ROBOT_MULTINODE_GLOBAL_MAX_QUEUED_CHUNKS must be a positive integer"
end

if fault_drop_responses < 0 do
  raise ArgumentError, "MODBUS_FAULT_DROP_RESPONSES must be a non-negative integer"
end

if fault_min_payload_bytes < 0 or fault_min_payload_bytes > 232 do
  raise ArgumentError, "MODBUS_FAULT_MIN_PAYLOAD_BYTES must be between 0 and 232"
end

if fault_after_ms < 0 do
  raise ArgumentError, "MODBUS_FAULT_AFTER_MS must be a non-negative integer"
end

if mission_timeout_ms < 1 do
  raise ArgumentError, "ROBOT_COMMAND_TIMEOUT_MS must be a positive integer"
end

if mission_retries < 0 do
  raise ArgumentError, "ROBOT_COMMAND_RETRIES must be a non-negative integer"
end

if mission_start_delay_ms < 0 do
  raise ArgumentError, "ROBOT_MISSION_START_DELAY_MS must be a non-negative integer"
end

if multinode_announce_ms < 1 do
  raise ArgumentError, "ROBOT_MULTINODE_ANNOUNCE_MS must be a positive integer"
end

if multinode_health_check_ms < 1 do
  raise ArgumentError, "ROBOT_MULTINODE_HEALTH_CHECK_MS must be a positive integer"
end

if multinode_lease_ms <= multinode_announce_ms do
  raise ArgumentError, "ROBOT_MULTINODE_LEASE_MS must be greater than ROBOT_MULTINODE_ANNOUNCE_MS"
end

if multinode_health_check_ms >= multinode_lease_ms do
  raise ArgumentError,
        "ROBOT_MULTINODE_HEALTH_CHECK_MS must be less than ROBOT_MULTINODE_LEASE_MS"
end

if multinode_soak_cycles < 0 do
  raise ArgumentError, "ROBOT_MULTINODE_SOAK_CYCLES must be a non-negative integer"
end

if multinode_soak_payload_bytes < 0 or multinode_soak_payload_bytes > 4_096 do
  raise ArgumentError, "ROBOT_MULTINODE_SOAK_PAYLOAD_BYTES must be between 0 and 4096"
end

if multinode_soak_interval_ms < 0 do
  raise ArgumentError, "ROBOT_MULTINODE_SOAK_INTERVAL_MS must be a non-negative integer"
end

if multinode_soak_retries < 0 do
  raise ArgumentError, "ROBOT_MULTINODE_SOAK_RETRIES must be a non-negative integer"
end

if multinode_traffic_samples < 0 or multinode_traffic_samples > 256 do
  raise ArgumentError, "ROBOT_MULTINODE_TRAFFIC_SAMPLES must be between 0 and 256"
end

if multinode_traffic_runs < 1 or multinode_traffic_runs > 1_000 do
  raise ArgumentError, "ROBOT_MULTINODE_TRAFFIC_RUNS must be between 1 and 1000"
end

if multinode_traffic_idle_ms < 0 do
  raise ArgumentError, "ROBOT_MULTINODE_TRAFFIC_IDLE_MS must be a non-negative integer"
end

if multinode_metrics_interval_ms < 0 do
  raise ArgumentError, "ROBOT_MULTINODE_METRICS_INTERVAL_MS must be a non-negative integer"
end

if multinode_traffic_drive_interval_ms < 1 or multinode_traffic_sensors_interval_ms < 1 do
  raise ArgumentError, "traffic producer intervals must be positive integers"
end

if multinode_traffic_payload_bytes < 0 or multinode_traffic_payload_bytes > 128 do
  raise ArgumentError, "ROBOT_MULTINODE_TRAFFIC_PAYLOAD_BYTES must be between 0 and 128"
end

if multinode_traffic_timeout_ms < 1 do
  raise ArgumentError, "ROBOT_MULTINODE_TRAFFIC_TIMEOUT_MS must be a positive integer"
end

if multinode_traffic_settle_ms < 0 do
  raise ArgumentError, "ROBOT_MULTINODE_TRAFFIC_SETTLE_MS must be a non-negative integer"
end

if multinode_traffic_start_delay_ms < 0 do
  raise ArgumentError, "ROBOT_MULTINODE_TRAFFIC_START_DELAY_MS must be a non-negative integer"
end

if multinode_traffic_ack_timeout_ms < 1 do
  raise ArgumentError, "ROBOT_MULTINODE_TRAFFIC_ACK_TIMEOUT_MS must be a positive integer"
end

if multinode_traffic_ack_retries < 0 do
  raise ArgumentError, "ROBOT_MULTINODE_TRAFFIC_ACK_RETRIES must be a non-negative integer"
end

if multinode_remote_health_enabled and
     multinode_remote_ack_timeout_ms <= multinode_announce_ms do
  raise ArgumentError,
        "ROBOT_MULTINODE_REMOTE_ACK_TIMEOUT_MS must be greater than ROBOT_MULTINODE_ANNOUNCE_MS"
end

if multinode_remote_max_restarts < 0 or multinode_remote_max_restarts > 10 do
  raise ArgumentError, "ROBOT_MULTINODE_REMOTE_MAX_RESTARTS must be between 0 and 10"
end

if multinode_lifecycle_probe_after_ms < 0 do
  raise ArgumentError,
        "ROBOT_MULTINODE_LIFECYCLE_PROBE_AFTER_MS must be a non-negative integer"
end

if multinode_defer_restart_until_transport_ready and not multinode_remote_health_enabled do
  raise ArgumentError,
        "ROBOT_MULTINODE_DEFER_RESTART_UNTIL_TRANSPORT_READYを有効にするにはROBOT_MULTINODE_REMOTE_HEALTH_ENABLED=trueが必要です"
end

if multinode_transport_activity_trace and not multinode_connection_trace do
  raise ArgumentError,
        "ROBOT_MULTINODE_TRANSPORT_ACTIVITY_TRACEを有効にするにはROBOT_MULTINODE_CONNECTION_TRACE=trueが必要です"
end

if multinode_transport_ready_confirmations < 1 or multinode_transport_ready_confirmations > 10 do
  raise ArgumentError, "ROBOT_MULTINODE_TRANSPORT_READY_CONFIRMATIONSは1から10の範囲で指定してください"
end

if sensor_mission_steps < 1 do
  raise ArgumentError, "ROBOT_SENSOR_MISSION_STEPS must be a positive integer"
end

if sensor_mission_step_delay_ms < 0 do
  raise ArgumentError, "ROBOT_SENSOR_MISSION_STEP_DELAY_MS must be a non-negative integer"
end

serial = [
  peripheral: System.get_env("ATOMVM_UART_PERIPHERAL") || "UART1",
  speed: parse_integer.("ATOMVM_UART_SPEED", 9_600),
  tx: parse_integer.("ATOMVM_UART_TX_PIN", 23),
  rx: parse_integer.("ATOMVM_UART_RX_PIN", 24),
  data_bits: 8,
  stop_bits: 1,
  parity: :none,
  rx_idle_timeout: 20
]

# Keep AtomVM's UART0 console free; use UART1 for Modbus on XIAO ESP32-C5.
config :avmodbus,
  uart_peripheral: serial[:peripheral],
  uart_speed: serial[:speed],
  uart_tx_pin: serial[:tx],
  uart_rx_pin: serial[:rx],
  uart_data_bits: serial[:data_bits],
  uart_stop_bits: serial[:stop_bits],
  uart_parity: serial[:parity],
  uart_rx_idle_timeout_ms: serial[:rx_idle_timeout],
  modbus_rtu_gap_ms: 0,
  modbus_silence_ms: 20

config :robot_sim,
  mode: mode,
  role: role,
  distributed_role: distributed_role,
  transport_role: transport_role,
  serial: serial,
  unit_id: unit_id,
  drive_unit_id: drive_unit_id,
  sensors_unit_id: sensors_unit_id,
  multidrop_cycles: multidrop_cycles,
  multidrop_interval_ms: multidrop_interval_ms,
  multidrop_start_delay_ms: multidrop_start_delay_ms,
  multidrop_gap_ms: multidrop_gap_ms,
  timeout_ms: parse_integer.("MODBUS_RESPONSE_TIMEOUT_MS", 500),
  bulk_timeout_ms: parse_integer.("MODBUS_BULK_RESPONSE_TIMEOUT_MS", 2_000),
  chunk_payload_bytes: chunk_payload_bytes,
  max_queued_bytes: max_queued_bytes,
  max_queued_chunks: max_queued_chunks,
  multinode_global_max_queued_bytes: multinode_global_max_queued_bytes,
  multinode_global_max_queued_chunks: multinode_global_max_queued_chunks,
  fault_drop_responses: fault_drop_responses,
  fault_min_payload_bytes: fault_min_payload_bytes,
  fault_after_ms: fault_after_ms,
  fault_rearm_on_restart: fault_rearm_on_restart,
  poll_ms: parse_integer.("MODBUS_POLL_INTERVAL_MS", 20),
  trace_transactions: System.get_env("MODBUS_TRACE_TRANSACTIONS") in ["1", "true"],
  trace_queue: System.get_env("MODBUS_TRACE_QUEUE") in ["1", "true"],
  trace_application: parse_boolean.("ROBOT_TRACE_APPLICATION", true),
  wait_for_peer: wait_for_peer,
  cookie: System.get_env("ATOMVM_COOKIE") || "AtomVM",
  mission_timeout_ms: mission_timeout_ms,
  mission_retries: mission_retries,
  mission_start_delay_ms: mission_start_delay_ms,
  multinode_announce_ms: multinode_announce_ms,
  multinode_health_check_ms: multinode_health_check_ms,
  multinode_lease_ms: multinode_lease_ms,
  multinode_soak_cycles: multinode_soak_cycles,
  multinode_soak_payload_bytes: multinode_soak_payload_bytes,
  multinode_soak_interval_ms: multinode_soak_interval_ms,
  multinode_soak_retries: multinode_soak_retries,
  multinode_traffic_samples: multinode_traffic_samples,
  multinode_traffic_runs: multinode_traffic_runs,
  multinode_traffic_idle_ms: multinode_traffic_idle_ms,
  multinode_metrics_interval_ms: multinode_metrics_interval_ms,
  multinode_traffic_drive_interval_ms: multinode_traffic_drive_interval_ms,
  multinode_traffic_sensors_interval_ms: multinode_traffic_sensors_interval_ms,
  multinode_traffic_payload_bytes: multinode_traffic_payload_bytes,
  multinode_traffic_timeout_ms: multinode_traffic_timeout_ms,
  multinode_traffic_settle_ms: multinode_traffic_settle_ms,
  multinode_traffic_start_delay_ms: multinode_traffic_start_delay_ms,
  multinode_traffic_ack_timeout_ms: multinode_traffic_ack_timeout_ms,
  multinode_traffic_ack_retries: multinode_traffic_ack_retries,
  multinode_restart_on_traffic_ack_timeout: multinode_restart_on_traffic_ack_timeout,
  multinode_remote_health_enabled: multinode_remote_health_enabled,
  multinode_remote_health_trace: multinode_remote_health_trace,
  multinode_defer_restart_until_transport_ready: multinode_defer_restart_until_transport_ready,
  multinode_transport_activity_trace: multinode_transport_activity_trace,
  multinode_exchange_trace: multinode_exchange_trace,
  multinode_transport_ready_confirmations: multinode_transport_ready_confirmations,
  multinode_connection_trace: multinode_connection_trace,
  multinode_initial_recovery_enabled: multinode_initial_recovery_enabled,
  multinode_remote_ack_timeout_ms: multinode_remote_ack_timeout_ms,
  multinode_remote_max_restarts: multinode_remote_max_restarts,
  multinode_lifecycle_probe_after_ms: multinode_lifecycle_probe_after_ms,
  multinode_application_recovery_probe_enabled: multinode_application_recovery_probe_enabled,
  sensor_mission_steps: sensor_mission_steps,
  sensor_mission_step_delay_ms: sensor_mission_step_delay_ms,
  drive_drop_first_reply_per_request: drive_drop_first_reply_per_request,
  first_request_id: parse_integer.("ROBOT_FIRST_REQUEST_ID", 1)
