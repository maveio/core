defmodule MaveCore.DeliveryStandby.Report do
  @moduledoc "Renders delivery standby sync and check results for a terminal."

  @doc "Formats the result of `MaveCore.DeliveryStandby.sync/1`."
  @spec sync(map()) :: String.t()
  def sync(report) do
    columns = [
      {"space", :space},
      {"objects", :objects},
      {"size", :bytes},
      {"copied", :copied},
      {"revoked", :revoked},
      {"removed", :orphans_deleted},
      {"held", :orphans_held},
      {"failed", :failed}
    ]

    title =
      if report.dry_run, do: "Delivery standby sync (dry run)", else: "Delivery standby sync"

    [
      title,
      table(columns, report.spaces, report.totals),
      notes(report.spaces),
      sync_status(report)
    ]
    |> join()
  end

  @doc "Formats the result of `MaveCore.DeliveryStandby.check/1`."
  @spec check(map()) :: String.t()
  def check(report) do
    columns = [
      {"space", :space},
      {"public objects", :objects},
      {"size", :bytes},
      {"current", :current},
      {"behind", :behind},
      {"not public", :not_public},
      {"probes passed", :probes_passed}
    ]

    [
      "Delivery standby check",
      table(columns, report.spaces, report.totals),
      "Last complete sync: #{last_sync(report)}\nStandby edge: #{report.edge_url || "not configured"}",
      findings(report.findings),
      verdict(report)
    ]
    |> join()
  end

  defp table(columns, spaces, totals) do
    rows = Enum.map(spaces, &row(columns, &1)) ++ [row(columns, Map.put(totals, :space, "total"))]
    header = Enum.map(columns, &elem(&1, 0))

    widths =
      [header | rows]
      |> Enum.zip_with(fn cells -> cells |> Enum.map(&String.length/1) |> Enum.max() end)

    [header | rows]
    |> Enum.map_join("\n", fn cells ->
      cells
      |> Enum.zip(widths)
      |> Enum.with_index()
      |> Enum.map_join("  ", fn
        {{cell, width}, 0} -> String.pad_trailing(cell, width)
        {{cell, width}, _index} -> String.pad_leading(cell, width)
      end)
      |> then(&("  " <> &1))
    end)
  end

  defp row(columns, values), do: Enum.map(columns, fn {_title, key} -> cell(key, values) end)

  defp cell(:bytes, values), do: size(Map.get(values, :bytes, 0))

  defp cell(:behind, values),
    do: to_string(Map.get(values, :missing, 0) + Map.get(values, :stale, 0))

  defp cell(key, values), do: to_string(Map.get(values, key, 0))

  defp notes(spaces) do
    lines =
      Enum.flat_map(spaces, fn space ->
        errors = if space.error, do: ["  #{space.space}  ERROR  #{space.error}"], else: []
        warnings = Enum.map(space.warnings, &"  #{space.space}  WARNING  #{&1}")
        failures = Enum.map(space.failures, &"  #{space.space}  FAILED  #{&1.key}: #{&1.reason}")
        errors ++ warnings ++ failures
      end)

    if lines != [], do: Enum.join(lines, "\n")
  end

  defp sync_status(%{dry_run: true}), do: "Nothing was changed."

  defp sync_status(%{partial: true}),
    do: "One space was synced; the stored status still describes the last complete run."

  defp sync_status(%{status_written: true, finished_at: finished_at}),
    do:
      "Status stored on the standby at #{DateTime.to_iso8601(DateTime.truncate(finished_at, :second))}."

  defp sync_status(_report), do: "WARNING: the status could not be stored on the standby."

  defp last_sync(%{last_sync: {:ok, %{"finished_at" => finished_at}}, checked_at: checked_at}) do
    case DateTime.from_iso8601(finished_at) do
      {:ok, time, _offset} ->
        "#{DateTime.to_iso8601(DateTime.truncate(time, :second))} (#{age(DateTime.diff(checked_at, time))} ago)"

      _invalid ->
        finished_at
    end
  end

  defp last_sync(_report), do: "never"

  defp findings([]), do: "Findings: none"

  defp findings(findings) do
    lines =
      findings
      |> Enum.sort_by(&{&1.severity != :critical, &1.space || ""})
      |> Enum.map_join("\n", fn finding ->
        severity =
          finding.severity |> Atom.to_string() |> String.upcase() |> String.pad_trailing(8)

        "  #{severity}  #{String.pad_trailing(finding.space || "-", 5)}  #{finding.code}: #{finding.detail}"
      end)

    "Findings\n" <> lines
  end

  defp verdict(%{ready?: true}), do: "READY: delivery can be switched to the standby."

  defp verdict(_report),
    do: "NOT READY: resolve the critical findings before relying on the standby."

  defp size(bytes) when bytes >= 1_073_741_824, do: "#{Float.round(bytes / 1_073_741_824, 1)} GB"
  defp size(bytes) when bytes >= 1_048_576, do: "#{Float.round(bytes / 1_048_576, 1)} MB"
  defp size(bytes) when bytes >= 1024, do: "#{Float.round(bytes / 1024, 1)} kB"
  defp size(bytes), do: "#{bytes} B"

  defp age(seconds) when seconds >= 7200, do: "#{div(seconds, 3600)} hours"
  defp age(seconds) when seconds >= 120, do: "#{div(seconds, 60)} minutes"
  defp age(seconds), do: "#{max(seconds, 0)} seconds"

  defp join(parts), do: parts |> Enum.reject(&is_nil/1) |> Enum.join("\n\n")
end
