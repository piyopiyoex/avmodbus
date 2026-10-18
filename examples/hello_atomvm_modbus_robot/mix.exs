defmodule RobotSim.MixProject do
  use Mix.Project

  def project do
    [
      app: :robot_sim,
      version: "0.1.0",
      elixir: "~> 1.19.0",
      deps: [],
      description: "Virtual rover experiment for distributed Erlang over Modbus RTU",
      start_permanent: Mix.env() == :prod
    ]
  end

  def application, do: []
end
