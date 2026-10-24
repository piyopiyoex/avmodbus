defmodule RobotSim.Controller do
  @moduledoc """
  Sequential mission controller for the virtual drive application protocol.

  A timeout retry reuses the same request ID so the drive can return a cached
  result instead of executing movement twice. An expected Drive boot ID can
  additionally prevent a retry from executing in a replacement Drive process.
  """

  alias RobotSim.{Protocol, Rover}

  @default_timeout_ms 1_000
  @default_max_retries 1

  @type destination :: pid() | atom() | {atom(), node()}
  @type command_result ::
          Protocol.result()
          | {:error,
             :timeout
             | {:indeterminate_command, Protocol.request_id(), Protocol.boot_id(),
                Protocol.boot_id()}}
  @type result ::
          command_result()
          | {:error, :drive_identity_timeout | {:unexpected_final_state, Rover.t()}}

  @doc "Run the reference mission and verify its final drive state."
  @spec demo(destination(), keyword()) :: result()
  def demo(destination, options \\ []) do
    case run(destination, RobotSim.mission(), options) do
      {:ok, rover} -> verify_demo_state(rover)
      {:error, _reason} = error -> error
    end
  end

  @doc "Run commands sequentially and return a final status response."
  @spec run(destination(), [RobotSim.Rover.command()], keyword()) :: command_result()
  def run(destination, commands, options \\ []) when is_list(commands) do
    first_request_id = Keyword.get(options, :first_request_id, 1)

    with :ok <- run_commands(destination, commands, first_request_id, options) do
      command(destination, first_request_id + length(commands), :status, options)
    end
  end

  @doc "Send one command, retrying a timeout with the same request ID."
  @spec command(destination(), Protocol.request_id(), RobotSim.Rover.command(), keyword()) ::
          command_result()
  def command(destination, request_id, rover_command, options \\ [])
      when is_integer(request_id) and request_id >= 0 do
    timeout_ms = Keyword.get(options, :timeout_ms, @default_timeout_ms)
    max_retries = Keyword.get(options, :max_retries, @default_max_retries)
    trace = Keyword.get(options, :trace, false)
    expected_boot_id = Keyword.get(options, :expected_boot_id)

    send_with_retry(
      destination,
      request_id,
      rover_command,
      expected_boot_id,
      timeout_ms,
      max_retries,
      trace,
      1
    )
  end

  @doc "Return the current volatile Drive boot identity."
  @spec drive_identity(destination(), keyword()) ::
          {:ok, Protocol.boot_id()} | {:error, :drive_identity_timeout}
  def drive_identity(destination, options \\ []) do
    timeout_ms = Keyword.get(options, :timeout_ms, @default_timeout_ms)
    reference = make_ref()
    send(destination, Protocol.identity_request(self(), reference))

    receive do
      {:drive_identity_reply, ^reference, boot_id}
      when is_integer(boot_id) and boot_id > 0 ->
        {:ok, boot_id}
    after
      timeout_ms -> {:error, :drive_identity_timeout}
    end
  end

  defp run_commands(destination, commands, first_request_id, options) do
    run_commands_loop(destination, commands, first_request_id, options)
  end

  defp run_commands_loop(_destination, [], _request_id, _options), do: :ok

  defp run_commands_loop(destination, [rover_command | rest], request_id, options) do
    case command(destination, request_id, rover_command, options) do
      {:ok, _rover} -> run_commands_loop(destination, rest, request_id + 1, options)
      {:error, _reason} = error -> error
    end
  end

  defp send_with_retry(
         destination,
         request_id,
         command,
         expected_boot_id,
         timeout_ms,
         retries_left,
         trace,
         attempt
       ) do
    trace(
      trace,
      "sending request_id=#{request_id} attempt=#{attempt} command=#{inspect(command)}"
    )

    send(destination, command_request(request_id, command, expected_boot_id))

    case await_reply(request_id, timeout_ms) do
      {:error, :timeout} when retries_left > 0 ->
        trace(trace, "request_id=#{request_id} timed out; retrying")

        send_with_retry(
          destination,
          request_id,
          command,
          expected_boot_id,
          timeout_ms,
          retries_left - 1,
          trace,
          attempt + 1
        )

      {:error, {:drive_boot_changed, current_boot_id}}
      when is_integer(expected_boot_id) and is_integer(current_boot_id) ->
        result =
          {:error, {:indeterminate_command, request_id, expected_boot_id, current_boot_id}}

        trace(trace, "received request_id=#{request_id} result=#{inspect(result)}")
        result

      result ->
        trace(trace, "received request_id=#{request_id} result=#{inspect(result)}")
        result
    end
  end

  defp command_request(request_id, command, nil),
    do: Protocol.request(self(), request_id, command)

  defp command_request(request_id, command, expected_boot_id),
    do: Protocol.guarded_request(self(), request_id, expected_boot_id, command)

  defp await_reply(request_id, timeout_ms) do
    deadline = :erlang.monotonic_time(:millisecond) + timeout_ms
    await_reply_until(request_id, deadline)
  end

  defp await_reply_until(request_id, deadline) do
    remaining_ms = max(deadline - :erlang.monotonic_time(:millisecond), 0)

    receive do
      {:robot_reply, ^request_id, result} ->
        result

      {:robot_reply, _stale_request_id, _result} ->
        await_reply_until(request_id, deadline)
    after
      remaining_ms -> {:error, :timeout}
    end
  end

  defp trace(false, _message), do: :ok
  defp trace(true, message), do: IO.puts("modbus_robot_controller: #{message}")

  defp verify_demo_state(rover) do
    if rover == RobotSim.expected_demo_state() do
      {:ok, rover}
    else
      {:error, {:unexpected_final_state, rover}}
    end
  end
end
