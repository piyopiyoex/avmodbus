defmodule RobotSim.MixProject do
  use Mix.Project

  def project do
    [
      app: :robot_sim,
      version: "0.1.0",
      elixir: "~> 1.19.0",
      deps: deps(),
      description: "Virtual rover experiment for distributed Erlang over Modbus RTU",
      atomvm: [start: RobotSim.Firmware],
      start_permanent: Mix.env() == :prod
    ]
  end

  def application, do: []

  defp deps do
    [
      {:disterl_probe, path: "../hello_atomvm_modbus_disterl"},
      {:exatomvm, github: "atomvm/exatomvm", runtime: false},
      {:atomvm, "~> 0.7.0-beta.0", runtime: false}
    ]
  end
end
