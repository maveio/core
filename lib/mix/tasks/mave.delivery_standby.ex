defmodule Mix.Tasks.Mave.DeliveryStandby do
  @shortdoc "Sync or check the emergency delivery standby"
  @moduledoc """
  Maintains the copy of public media at an independent provider that delivery
  can be switched to in an emergency. See `docs/emergency_delivery_failover.md`.

      mix mave.delivery_standby sync [--space HASH] [--dry-run] [--force-deletes]
      mix mave.delivery_standby check [--space HASH] [--max-age SECONDS]

  `check` exits with status 1 when the standby is not ready. Add `--json` for
  machine-readable output. A release runs the same commands with
  `bin/mave_core eval 'MaveCore.Release.delivery_standby("check")'`.
  """

  use Mix.Task

  alias MaveCore.DeliveryStandby.CLI

  @impl Mix.Task
  def run(args) do
    # Keep the report readable in development, where queries are logged.
    Logger.configure(level: :warning)
    Mix.Task.run("app.start")

    case CLI.run(args) do
      :ok -> :ok
      {:error, message} -> Mix.raise(message)
      :not_ready -> exit({:shutdown, 1})
    end
  end
end
