defmodule MaveCore.Workers.MultiRegionMonitorWorker do
  @moduledoc """
  Checks region health for spaces with replica regions, moves delivery when a
  region fails or recovers, and queues the periodic full replication pass.

  Runs every minute for all spaces, and on demand for one space.
  """
  use Oban.Worker,
    queue: :multi_region,
    max_attempts: 1,
    unique: [period: :infinity, states: [:available, :scheduled, :executing, :retryable]]

  alias MaveCore.MultiRegion
  alias MaveCore.MultiRegion.Health
  alias MaveCore.Repo
  alias MaveCore.Spaces.Space
  alias MaveCore.Workers.MultiRegionSyncWorker

  @impl true
  def perform(%Oban.Job{args: %{"space_id" => space_id}}) do
    case Repo.get(Space, space_id) do
      %Space{deleted_at: nil} = space -> if MultiRegion.enabled?(space), do: Health.check([space])
      _other -> :ok
    end

    :ok
  end

  def perform(_job) do
    case MultiRegion.list_replicated_spaces() do
      [] ->
        :ok

      spaces ->
        Health.check(spaces)
        Enum.each(spaces, &queue_due_syncs/1)
    end
  end

  defp queue_due_syncs(space) do
    now = DateTime.utc_now()

    replicas = MultiRegion.replica_regions(space)

    space
    |> MultiRegion.list_states()
    |> Enum.filter(&(&1.region in replicas and MultiRegionSyncWorker.due?(&1, now)))
    |> Enum.each(&MultiRegion.request_sync(space, &1.region))
  end
end
