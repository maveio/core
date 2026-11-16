defmodule MaveCore.DeliveryStandby.CLI do
  @moduledoc "Command-line entry point shared by the Mix task and release commands."

  alias MaveCore.DeliveryStandby
  alias MaveCore.DeliveryStandby.Report

  @switches [
    space: :string,
    dry_run: :boolean,
    force_deletes: :boolean,
    max_age: :integer,
    json: :boolean
  ]

  @usage "Usage: sync [--space HASH] [--dry-run] [--force-deletes] | check [--space HASH] [--max-age SECONDS] [--json]"

  @not_configured "No delivery standby is configured. Set MAVE_DELIVERY_STANDBY_S3_ENDPOINT and its keys."

  @doc """
  Runs `sync` or `check` and prints the result.

  Returns `:not_ready` when a check finds the standby unfit for a switch.
  """
  @spec run([String.t()]) :: :ok | :not_ready | {:error, String.t()}
  def run(args) when is_list(args) do
    case OptionParser.parse(args, strict: @switches) do
      {opts, ["sync"], []} -> sync(opts)
      {opts, ["check"], []} -> check(opts)
      _invalid -> {:error, @usage}
    end
  end

  defp sync(opts) do
    options =
      [
        space: opts[:space],
        dry_run: opts[:dry_run] == true,
        force_deletes: opts[:force_deletes] == true
      ]

    case DeliveryStandby.sync(options) do
      {:ok, report} ->
        print(report, &Report.sync/1, opts)

        if incomplete?(report),
          do: {:error, "The sync did not complete for every object."},
          else: :ok

      {:error, :delivery_standby_not_configured} ->
        {:error, @not_configured}
    end
  end

  defp check(opts) do
    case DeliveryStandby.check(space: opts[:space], max_age_seconds: opts[:max_age]) do
      {:ok, report} ->
        print(report, &Report.check/1, opts)
        if report.ready?, do: :ok, else: :not_ready

      {:error, :delivery_standby_not_configured} ->
        {:error, @not_configured}
    end
  end

  defp incomplete?(report),
    do: report.totals.failed > 0 or Enum.any?(report.spaces, &is_binary(&1.error))

  defp print(report, formatter, opts) do
    if opts[:json],
      do: report |> jsonable() |> Jason.encode!(pretty: true) |> IO.puts(),
      else: report |> formatter.() |> IO.puts()
  end

  defp jsonable(%{last_sync: last_sync} = report) do
    status =
      case last_sync do
        {:ok, status} -> status
        _missing -> nil
      end

    %{report | last_sync: status}
  end

  defp jsonable(report), do: report
end
