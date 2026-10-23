defmodule MaveCore.Workers.AnalyticsSessionsWorker do
  @moduledoc "Refreshes bounded session buckets using the durable event inventory."
  use Oban.Worker,
    queue: :analytics,
    max_attempts: 5,
    unique: [period: :infinity, states: [:available, :scheduled, :executing, :retryable]]

  alias MaveCore.Analytics.Sessions

  @impl true
  def perform(_job) do
    config = Application.get_env(:mave_core, :analytics_sessions, [])
    spaces = Keyword.get(config, :process_spaces, :all)

    if Sessions.processing_enabled?() and spaces != [] do
      with {:ok, _} <- Sessions.refresh_changed(spaces: spaces), do: :ok
    else
      :ok
    end
  end
end
