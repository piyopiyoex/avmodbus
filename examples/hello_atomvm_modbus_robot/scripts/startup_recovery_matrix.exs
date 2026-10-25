Code.require_file("../host/startup_recovery_matrix.ex", __DIR__)

alias RobotSim.StartupRecoveryMatrix

case System.argv() do
  [] ->
    IO.puts("startup_recovery_matrix: scenarios")

    Enum.each(StartupRecoveryMatrix.matrix(), fn scenario ->
      IO.puts(
        "id=#{scenario.id} category=#{scenario.category} " <>
          "boot_order=#{Enum.join(scenario.boot_order, ",")} " <>
          "fault_role=#{scenario.fault_role || :none} " <>
          "required_events=#{length(scenario.required)}"
      )
    end)

  [scenario_text, path] ->
    scenario =
      Enum.find(StartupRecoveryMatrix.matrix(), &(Atom.to_string(&1.id) == scenario_text))

    if scenario == nil do
      IO.puts(:stderr, "unknown scenario: #{scenario_text}")
      System.halt(1)
    end

    case StartupRecoveryMatrix.evaluate_lines(scenario.id, File.stream!(path)) do
      {:ok, report} ->
        IO.inspect(report, label: "startup_recovery_matrix")
        if report.outcome in [:passed, :recovered_after_failure], do: :ok, else: System.halt(2)

      {:error, reason} ->
        IO.puts(:stderr, "invalid trace: #{inspect(reason)}")
        System.halt(1)
    end

  _other ->
    IO.puts(:stderr, "usage: mix run scripts/startup_recovery_matrix.exs [SCENARIO LOG_FILE]")
    System.halt(1)
end
