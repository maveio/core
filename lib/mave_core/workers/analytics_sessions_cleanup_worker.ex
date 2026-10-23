defmodule MaveCore.Workers.AnalyticsSessionsCleanupWorker do
  @moduledoc "Collects superseded session generations outside interactive requests."
  use Oban.Worker,
    queue: :analytics,
    max_attempts: 3,
    unique: [period: :infinity, states: [:available, :scheduled, :executing, :retryable]]

  alias MaveCore.Analytics.Sessions

  @impl true
  def perform(_job) do
    if Sessions.enabled?() or Sessions.processing_enabled?(),
      do: Sessions.cleanup(),
      else: :ok
  end
end
