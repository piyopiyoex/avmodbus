defmodule RobotSim.Relay do
  @moduledoc """
  Controller-mediated application relay from Sensors to Drive.

  The Controller first requests a sample from Sensors and then forwards the
  validated sample to Drive. The two Modbus Server nodes never initiate a
  physical bus transaction or connect directly to each other.
  """

  alias RobotSim.Sensors

  @default_timeout_ms 5_000

  @type result :: %{
          sensors_node: node(),
          drive_node: node(),
          sample: Sensors.sample()
        }

  @doc "Request one sensor sample and relay it to Drive."
  @spec run(GenServer.server(), GenServer.server(), keyword()) ::
          {:ok, result()} | {:error, term()}
  def run(sensors, drive, options \\ []) do
    timeout_ms = Keyword.get(options, :timeout_ms, @default_timeout_ms)
    reference = make_ref()
    send(sensors, {:sensor_request, self(), reference})

    receive do
      {:sensor_reply, ^reference, sensors_node, sample} ->
        forward_sample(drive, sensors_node, sample, timeout_ms)
    after
      timeout_ms -> {:error, :sensor_timeout}
    end
  end

  defp forward_sample(drive, sensors_node, sample, timeout_ms) do
    if Sensors.valid_sample?(sample) do
      reference = make_ref()
      send(drive, {:relayed_sensor_sample, self(), reference, sensors_node, sample})

      receive do
        {:sensor_sample_accepted, ^reference, drive_node, ^sample} ->
          {:ok, %{sensors_node: sensors_node, drive_node: drive_node, sample: sample}}

        {:sensor_sample_rejected, ^reference, drive_node, reason} ->
          {:error, {:drive_rejected, drive_node, reason}}
      after
        timeout_ms -> {:error, :drive_timeout}
      end
    else
      {:error, {:invalid_sensor_sample, sample}}
    end
  end
end
