Code.require_file("../host/endurance_report.ex", __DIR__)

alias RobotSim.EnduranceReport

{options, paths, invalid} =
  OptionParser.parse(System.argv(), strict: [since: :string, until: :string])

case {paths, invalid} do
  {[controller_path, drive_path, sensors_path], []} ->
    {:ok, report} =
      EnduranceReport.analyze(
        %{
          controller: File.read!(controller_path),
          drive: File.read!(drive_path),
          sensors: File.read!(sensors_path)
        },
        options
      )

    IO.inspect(report, pretty: true, limit: :infinity)

  _arguments ->
    IO.puts(
      "usage: mix run scripts/endurance_report.exs " <>
        "[--since HH:MM:SS.mmm] [--until HH:MM:SS.mmm] " <>
        "CONTROLLER_LOG DRIVE_LOG SENSORS_LOG"
    )

    System.halt(2)
end
