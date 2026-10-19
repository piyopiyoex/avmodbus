defmodule RobotSim.Firmware do
  @moduledoc "AtomVM entry point that selects the configured experiment mode."

  @mode Application.compile_env(:robot_sim, :mode, :distributed)

  @doc "Start the configured robot experiment mode."
  @spec start() :: no_return()
  def start do
    case @mode do
      :distributed -> RobotSim.Distributed.start()
      :multidrop -> RobotSim.Multidrop.start()
      :multinode -> RobotSim.MultinodeDistributed.start()
    end
  end
end
