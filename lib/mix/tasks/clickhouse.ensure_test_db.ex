defmodule Mix.Tasks.Clickhouse.EnsureTestDb do
  use Mix.Task

  alias Mix.Tasks.Perf.ClickHouseHTTP

  @shortdoc "Ensure the ClickHouse test database exists"

  @moduledoc """
  Ensures the ClickHouse test database exists.

  The ClickHouse Ecto adapter expects the configured database to exist in order
  to connect, so we create it explicitly before running `ecto.migrate` in test.

  This prevents `mix test`/`mix precommit` from using (and truncating) the dev
  ClickHouse database.
  """

  @impl true
  def run(_args) do
    Mix.Task.run("app.config")

    db_name =
      Application.get_env(:mave_core, MaveCore.ClickHouseRepo, [])
      |> Keyword.get(:database, "mave_metrics_test")

    _ =
      ClickHouseHTTP.execute!(
        "CREATE DATABASE IF NOT EXISTS #{db_name}",
        database: "default"
      )

    Mix.shell().info("Ensured ClickHouse database exists: #{db_name}")
  end
end
