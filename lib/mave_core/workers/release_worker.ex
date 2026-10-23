defmodule MaveCore.Workers.ReleaseWorker do
  @moduledoc """
  Publishes scheduled releases.

  Scheduling inserts one job per release at `release_at`. The cron entry without
  arguments sweeps due releases every minute, covering jobs lost to downtime or
  releases rescheduled while a job was already queued. Both paths are idempotent.
  """
  use Oban.Worker, queue: :flow_low, max_attempts: 10

  require Logger

  alias MaveCore.Embeds.Release

  @impl true
  def perform(%Oban.Job{args: %{"embed_id" => embed_id}}) do
    case Release.release_due(embed_id) do
      {:ok, {:not_due, seconds}} -> {:snooze, seconds}
      {:ok, _embed} -> :ok
      {:error, reason} -> {:error, reason}
    end
  end

  def perform(%Oban.Job{}) do
    Enum.each(Release.due_embed_ids(), fn embed_id ->
      case Release.release_due(embed_id) do
        {:ok, _result} ->
          :ok

        {:error, reason} ->
          Logger.warning("Scheduled release #{embed_id} failed: #{inspect(reason)}")
      end
    end)
  end
end
