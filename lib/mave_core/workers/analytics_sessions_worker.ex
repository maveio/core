defmodule MaveCore.Workers.AnalyticsSessionsWorker do
  @moduledoc "Refreshes bounded session buckets using the durable event inventory."
  use Oban.Worker,
    queue: :analytics,
    max_attempts: 5,
    unique: [period: :infinity, states: [:available, :scheduled, :executing, :retryable]]

  alias MaveCore.Analytics.Sessions

  @impl true
  def perform(_job) do
    if Sessions.processing_enabled?() do
      with {:ok, _} <- Sessions.refresh_changed(), do: :ok
    else
      :ok
    end
  end
end
