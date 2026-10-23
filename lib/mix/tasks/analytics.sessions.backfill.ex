defmodule Mix.Tasks.Analytics.Sessions.Backfill do
  use Mix.Task
  @moduledoc "Resumable maintenance command for prepared analytics."
  alias MaveCore.Analytics.Sessions
  alias MaveCore.ClickHouseRepo

  @shortdoc "Build or resume prepared analytics sessions in bounded buckets"

  @impl true
  def run(args) do
    {opts, rest, invalid} =
      OptionParser.parse(args,
        strict: [
          rounds: :integer,
          limit: :integer,
          materialize_inventory: :boolean,
          materialize_session_revisions: :boolean,
          space: :string
        ]
      )

    rounds = Keyword.get(opts, :rounds, 100)
    limit = Keyword.get(opts, :limit, 16)
    space = Keyword.get(opts, :space)

    validate_options!(rest, invalid, rounds, limit, space)

    Mix.Task.run("app.start")

    if Keyword.get(opts, :materialize_inventory, false) do
      ClickHouseRepo.query!(
        "ALTER TABLE events MATERIALIZE PROJECTION analytics_session_inventory SETTINGS mutations_sync = 1",
        [],
        timeout: :infinity
      )
    end

    if Keyword.get(opts, :materialize_session_revisions, false) do
      ClickHouseRepo.query!(
        "ALTER TABLE events MATERIALIZE PROJECTION analytics_session_revisions SETTINGS mutations_sync = 1",
        [],
        timeout: :infinity
      )
    end

    Enum.reduce_while(1..rounds, :ok, fn round, :ok ->
      case Sessions.refresh_changed(limit: limit, space_hash: space) do
        {:ok, 0} ->
          Mix.shell().info("Session inventory is up to date.")
          {:halt, :ok}

        {:ok, count} ->
          Mix.shell().info("Round #{round}: published #{count} session buckets.")
          {:cont, :ok}

        {:error, reason} ->
          Mix.raise("Session backfill stopped: #{inspect(reason)}")
      end
    end)
  end

  defp validate_options!(rest, invalid, rounds, limit, space) do
    unless rest == [] and invalid == [] and rounds in 1..1000 and limit in 1..64 and
             valid_space?(space) do
      Mix.raise(
        "Expected --rounds 1..1000, --limit 1..64, --space HASH, or --materialize-inventory / --materialize-session-revisions"
      )
    end
  end

  defp valid_space?(nil), do: true
  defp valid_space?(space), do: Regex.match?(~r/\A[A-Za-z0-9]{5}\z/, space)
end
