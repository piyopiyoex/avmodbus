defmodule RobotSim.Firmware do
  @moduledoc "AtomVM entry point that selects the configured experiment mode."

  @mode Application.compile_env(:robot_sim, :mode, :distributed)

  @doc "Start the configured distributed mission or standard Modbus multidrop probe."
  @spec start() :: no_return()
  def start do
    case @mode do
      :distributed -> RobotSim.Distributed.start()
      :multidrop -> RobotSim.Multidrop.start()
    end
  end
end
