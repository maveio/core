defmodule MaveCore.Workers.CliAuthorizationPruneWorker do
  @moduledoc """
  Removes CLI device authorizations that expired more than a day ago.
  """
  use Oban.Worker, queue: :flow_low, max_attempts: 3

  alias MaveCore.CliAuthorizations

  @batch_size 10_000

  @impl true
  def perform(_job) do
    case CliAuthorizations.prune_expired(batch_size: @batch_size) do
      {:ok, @batch_size} -> {:snooze, 1}
      {:ok, _count} -> :ok
    end
  end
end
