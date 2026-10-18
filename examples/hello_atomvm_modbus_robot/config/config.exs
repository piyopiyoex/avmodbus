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

role = if System.get_env("ROBOT_ROLE") == "drive", do: :drive, else: :controller
transport_role = if role == :drive, do: :server, else: :client
chunk_payload_bytes = parse_integer.("MODBUS_CHUNK_PAYLOAD_BYTES", 96)
max_queued_bytes = parse_integer.("MODBUS_MAX_QUEUED_BYTES", 8_192)
max_queued_chunks = parse_integer.("MODBUS_MAX_QUEUED_CHUNKS", 256)
mission_timeout_ms = parse_integer.("ROBOT_COMMAND_TIMEOUT_MS", 60_000)
mission_retries = parse_integer.("ROBOT_COMMAND_RETRIES", 1)
mission_start_delay_ms = parse_integer.("ROBOT_MISSION_START_DELAY_MS", 2_000)
wait_for_peer = parse_boolean.("MODBUS_WAIT_FOR_PEER", role == :controller)

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
  role: role,
  transport_role: transport_role,
  serial: serial,
  unit_id: parse_integer.("MODBUS_UNIT_ID", 1),
  timeout_ms: parse_integer.("MODBUS_RESPONSE_TIMEOUT_MS", 500),
  bulk_timeout_ms: parse_integer.("MODBUS_BULK_RESPONSE_TIMEOUT_MS", 2_000),
  chunk_payload_bytes: chunk_payload_bytes,
  max_queued_bytes: max_queued_bytes,
  max_queued_chunks: max_queued_chunks,
  poll_ms: parse_integer.("MODBUS_POLL_INTERVAL_MS", 20),
  trace_transactions: System.get_env("MODBUS_TRACE_TRANSACTIONS") in ["1", "true"],
  trace_queue: System.get_env("MODBUS_TRACE_QUEUE") in ["1", "true"],
  wait_for_peer: wait_for_peer,
  cookie: System.get_env("ATOMVM_COOKIE") || "AtomVM",
  mission_timeout_ms: mission_timeout_ms,
  mission_retries: mission_retries,
  mission_start_delay_ms: mission_start_delay_ms,
  first_request_id: parse_integer.("ROBOT_FIRST_REQUEST_ID", 1)
