defmodule MaveCore.Workers.MultiRegionSyncWorker do
  @moduledoc """
  Replicates a space's media to one replica region, or removes it from a region
  that is no longer a replica.

  A job that is already waiting absorbs identical requests. A running job does
  not, so a change that arrives mid-run still gets its own pass.
  """
  use Oban.Worker,
    queue: :multi_region,
    max_attempts: 5,
    unique: [period: :infinity, states: [:available, :scheduled, :retryable]]

  alias MaveCore.MultiRegion
  alias MaveCore.MultiRegion.{RegionState, Replicator}
  alias MaveCore.Repo
  alias MaveCore.Spaces.Space

  @impl true
  def perform(%Oban.Job{args: %{"space_id" => space_id, "region" => region} = args}) do
    case Repo.get(Space, space_id) do
      %Space{deleted_at: nil} = space -> run(space, region, args)
      _other -> :ok
    end
  end

  defp run(space, region, %{"action" => "purge"}) do
    # The region may have been added again since the removal was requested.
    if region in MultiRegion.replica_regions(space),
      do: :ok,
      else: Replicator.purge(space, region)
  end

  defp run(space, region, args) do
    cond do
      region not in MultiRegion.replica_regions(space) -> :ok
      # Nothing can be read from a primary that is down. Wait instead of
      # reporting the replica as failed.
      primary_unavailable?(space) -> {:snooze, 60}
      true -> sync(space, region, Map.get(args, "prefix"))
    end
  end

  defp primary_unavailable?(space) do
    match?(
      %RegionState{health: "unavailable"},
      MultiRegion.get_state(space, MultiRegion.primary_region(space))
    )
  end

  defp sync(space, region, prefix) do
    full? = prefix in [nil, ""]
    now = DateTime.utc_now()

    if full? do
      MultiRegion.update_state(space, region, %{sync_status: "syncing", sync_started_at: now})
    end

    case Replicator.sync(space, region, prefix: prefix || "") do
      {:ok, stats} ->
        MultiRegion.update_state(space, region, synced_attrs(full?, stats))
        :ok

      {:error, reason} ->
        MultiRegion.update_state(space, region, %{
          sync_status: "failed",
          sync_error: describe(reason)
        })

        {:error, reason}
    end
  end

  defp synced_attrs(true, stats) do
    %{
      sync_status: "synced",
      sync_error: nil,
      synced_at: DateTime.utc_now(),
      objects_total: stats.objects,
      bytes_total: stats.bytes,
      objects_pending: 0,
      last_copied: stats.copied,
      last_deleted: stats.deleted
    }
  end

  # A change-driven pass covers one embed. It keeps a complete replica current,
  # but cannot make an incomplete one complete.
  defp synced_attrs(false, _stats), do: %{}

  defp describe({:copy_failed, key, _reason}), do: "could not copy #{key}"
  defp describe({:delete_failed, key, _reason}), do: "could not delete #{key}"
  defp describe(:replica_is_primary_bucket), do: "region uses the same bucket as the primary"
  defp describe(%{__exception__: true} = exception), do: Exception.message(exception)
  defp describe(reason), do: inspect(reason)

  @doc false
  def due?(%RegionState{sync_status: "synced", synced_at: %DateTime{} = synced_at}, now) do
    DateTime.diff(now, synced_at) >= MultiRegion.config(:reconcile_interval_seconds)
  end

  def due?(%RegionState{sync_status: "syncing", sync_started_at: %DateTime{} = started_at}, now) do
    # A run that never reported back, for example because its node went away.
    DateTime.diff(now, started_at) >= 4 * MultiRegion.config(:reconcile_interval_seconds)
  end

  def due?(%RegionState{sync_status: "syncing"}, _now), do: false
  def due?(%RegionState{}, _now), do: true
end
