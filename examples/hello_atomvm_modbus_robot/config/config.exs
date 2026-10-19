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
sensor_mission_steps = parse_integer.("ROBOT_SENSOR_MISSION_STEPS", 3)
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

if sensor_mission_steps < 1 do
  raise ArgumentError, "ROBOT_SENSOR_MISSION_STEPS must be a positive integer"
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
  sensor_mission_steps: sensor_mission_steps,
  first_request_id: parse_integer.("ROBOT_FIRST_REQUEST_ID", 1)
