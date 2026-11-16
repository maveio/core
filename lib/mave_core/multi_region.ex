defmodule MaveCore.MultiRegion do
  @moduledoc """
  Optional multi-region delivery for a space.

  A space keeps one primary region (`space.region`), where uploads and processing
  write. `replica_regions` are additional storage profiles that receive a copy of
  the space's public media. `delivery_region` is the region that currently serves
  viewers; it follows region health when failover is automatic.

  See `docs/multi_region_delivery.md` for configuration and behavior.
  """
  import Ecto.Query

  require Logger

  alias MaveCore.Media.Storage
  alias MaveCore.MultiRegion.{Cache, RegionState}
  alias MaveCore.Repo
  alias MaveCore.SharedStorageSpace
  alias MaveCore.Spaces.{Events, Space}
  alias MaveCore.StorageProfiles
  alias MaveCore.UsageLimits
  alias MaveCore.Workers.{MultiRegionMonitorWorker, MultiRegionSyncWorker}

  @max_replicas 3
  @region_format ~r/\A[a-z0-9][a-z0-9_-]{0,31}\z/

  @defaults [
    # Probes that must fail in a row, within one check, before a region counts as down.
    failure_threshold: 3,
    probe_retry_delay_ms: 5_000,
    probe_timeout_ms: 5_000,
    # Successful checks in a row before a region that was down counts as healthy again.
    recovery_threshold: 2,
    # Full comparison of a replica against the primary, as a safety net for changes
    # that did not announce themselves.
    reconcile_interval_seconds: 900,
    # Embed changes within this window share one replication pass.
    change_debounce_seconds: 10,
    copy_concurrency: 4,
    redirect_max_age_seconds: 30
  ]

  @doc "Reads a multi-region setting, falling back to its default."
  def config(key) when is_atom(key) do
    :mave_core
    |> Application.get_env(:multi_region, [])
    |> Keyword.get(key, Keyword.fetch!(@defaults, key))
  end

  def max_replicas, do: @max_replicas

  ## Regions

  def primary_region(%Space{} = space), do: StorageProfiles.for_space(space)

  def replica_regions(%Space{replica_regions: regions} = space) when is_list(regions) do
    primary = primary_region(space)

    regions
    |> Enum.filter(&is_binary/1)
    |> Enum.reject(&(&1 == primary))
    |> Enum.uniq()
  end

  def replica_regions(_space), do: []

  @doc "The primary region followed by the replicas, in failover order."
  def regions(%Space{} = space), do: [primary_region(space) | replica_regions(space)]

  def enabled?(%Space{} = space), do: replica_regions(space) != []

  @doc "The region that serves viewers right now."
  def delivery_region(%Space{delivery_region: region} = space) when is_binary(region) do
    if region in regions(space), do: region, else: primary_region(space)
  end

  def delivery_region(%Space{} = space), do: primary_region(space)

  @doc """
  Storage profiles a space could add as a replica: configured, not the primary,
  and backed by a different bucket than the primary.
  """
  def selectable_regions(%Space{} = space) do
    primary = primary_region(space)
    primary_bucket = Storage.bucket_for_space(space.hash, primary)

    :mave_core
    |> Application.get_env(:storage_providers, %{})
    |> Map.keys()
    |> Enum.map(&to_string/1)
    |> Enum.filter(&Regex.match?(@region_format, &1))
    |> Enum.reject(fn region ->
      region == primary or
        Storage.same_bucket?(
          region,
          Storage.bucket_for_space(space.hash, region),
          primary,
          primary_bucket
        )
    end)
    |> Enum.sort()
  end

  @doc "Whether the space may use multi-region delivery at all."
  def available?(%Space{} = space) do
    not SharedStorageSpace.shared?(space) and
      (enabled?(space) or selectable_regions(space) != []) and
      UsageLimits.can_use_multi_region?(space) == :ok
  end

  ## Customer controls

  @doc "Adds a replica region and starts copying the space's media to it."
  def add_region(%Space{} = space, region) when is_binary(region) do
    replicas = replica_regions(space)

    cond do
      SharedStorageSpace.shared?(space) ->
        {:error, :shared_storage_space}

      UsageLimits.can_use_multi_region?(space) != :ok ->
        UsageLimits.can_use_multi_region?(space)

      region in replicas ->
        {:ok, space}

      region not in selectable_regions(space) ->
        {:error, :unknown_region}

      length(replicas) >= @max_replicas ->
        {:error, :too_many_regions}

      true ->
        with {:ok, space} <- update_space(space, %{replica_regions: replicas ++ [region]}) do
          ensure_state(space, primary_region(space))
          reset_sync_state(space, region)
          request_sync(space, region)
          {:ok, space}
        end
    end
  end

  def add_region(_space, _region), do: {:error, :unknown_region}

  @doc """
  Removes a replica region. Delivery returns to the primary when the removed
  region was serving, and the replica's copy of the media is deleted.
  """
  def remove_region(%Space{} = space, region) when is_binary(region) do
    replicas = replica_regions(space)

    if region in replicas do
      do_remove_region(space, region, replicas -- [region])
    else
      {:ok, space}
    end
  end

  defp do_remove_region(space, region, remaining) do
    attrs =
      if space.delivery_region == region do
        %{
          replica_regions: remaining,
          delivery_region: nil,
          delivery_region_reason: "region_removed",
          delivery_region_changed_at: DateTime.utc_now()
        }
      else
        %{replica_regions: remaining}
      end

    with {:ok, updated} <- update_space(space, attrs) do
      # Without replicas there is nothing left to track, the primary included.
      stale_states =
        if remaining == [],
          do: from(s in RegionState, where: s.space_id == ^space.id),
          else: from(s in RegionState, where: s.space_id == ^space.id and s.region == ^region)

      Repo.delete_all(stale_states)

      %{"space_id" => space.id, "region" => region, "action" => "purge"}
      |> MultiRegionSyncWorker.new()
      |> Oban.insert()

      if space.delivery_region == region do
        notify_router(updated, region, primary_region(updated), "region_removed")
      end

      {:ok, updated}
    end
  end

  @doc "Chooses whether delivery follows region health (`automatic`) or stays put (`manual`)."
  def set_failover_mode(%Space{} = space, mode) when mode in ["automatic", "manual"] do
    update_space(space, %{delivery_failover: mode})
  end

  def set_failover_mode(_space, _mode), do: {:error, :invalid_failover_mode}

  @doc """
  Serves viewers from `region`. A replica has to hold a complete copy first.
  """
  def set_delivery_region(%Space{} = space, region, reason \\ "manual") when is_binary(region) do
    current = delivery_region(space)
    primary = primary_region(space)

    cond do
      region not in regions(space) ->
        {:error, :unknown_region}

      region == current ->
        {:ok, space}

      region != primary and not synced?(space, region) ->
        {:error, :region_not_synced}

      true ->
        attrs = %{
          delivery_region: if(region == primary, do: nil, else: region),
          delivery_region_reason: reason,
          delivery_region_changed_at: DateTime.utc_now()
        }

        with {:ok, updated} <- update_space(space, attrs) do
          Logger.warning(
            "Delivery for space #{space.hash} moved from #{current} to #{region} (#{reason})"
          )

          notify_router(updated, current, region, reason)
          {:ok, updated}
        end
    end
  end

  @doc "Queues a full comparison of every replica against the primary."
  def request_sync(%Space{} = space) do
    Enum.each(replica_regions(space), &request_sync(space, &1))
  end

  @doc "Queues a comparison of one replica, optionally limited to an object prefix."
  def request_sync(%Space{} = space, region, opts \\ []) when is_binary(region) do
    args = %{"space_id" => space.id, "region" => region, "action" => "sync"}

    args =
      case Keyword.get(opts, :prefix) do
        prefix when is_binary(prefix) and prefix != "" -> Map.put(args, "prefix", prefix)
        _prefix -> args
      end

    args
    |> MultiRegionSyncWorker.new(schedule_in: Keyword.get(opts, :schedule_in, 0))
    |> Oban.insert()
  end

  @doc "Queues a health check of the space's regions."
  def request_health_check(%Space{} = space) do
    %{"space_id" => space.id}
    |> MultiRegionMonitorWorker.new()
    |> Oban.insert()
  end

  ## Change tracking

  @doc """
  Called when an embed of a space changed. Replicates that embed's objects soon
  after, so replicas do not wait for the next full comparison.
  """
  def embed_changed(space_id, embed_id) when is_binary(space_id) and is_binary(embed_id) do
    with true <- replicated_space?(space_id),
         %Space{} = space <- Repo.get(Space, space_id),
         hash when is_binary(hash) <- embed_hash(embed_id) do
      opts = [prefix: hash <> "/", schedule_in: config(:change_debounce_seconds)]
      Enum.each(replica_regions(space), &request_sync(space, &1, opts))
    end

    :ok
  end

  def embed_changed(_space_id, _embed_id), do: :ok

  defp replicated_space?(space_id) do
    Cache.fetch({:replicated, space_id}, 30_000, fn ->
      Repo.exists?(
        from(s in Space,
          where:
            s.id == ^space_id and is_nil(s.deleted_at) and
              fragment("cardinality(?) > 0", s.replica_regions)
        )
      )
    end)
  end

  defp embed_hash(embed_id) do
    Repo.one(from(e in MaveCore.Embeds.Embed, where: e.id == ^embed_id, select: e.hash))
  end

  ## State

  @doc "Spaces that have at least one replica region."
  def list_replicated_spaces do
    Repo.all(
      from(s in Space,
        where: is_nil(s.deleted_at) and fragment("cardinality(?) > 0", s.replica_regions),
        order_by: [asc: s.inserted_at]
      )
    )
  end

  @doc """
  Region states of a space in failover order. Regions without a stored state get
  a blank one, so callers can render every region.
  """
  def list_states(%Space{} = space) do
    stored =
      from(s in RegionState, where: s.space_id == ^space.id)
      |> Repo.all()
      |> Map.new(&{&1.region, &1})

    Enum.map(regions(space), fn region ->
      Map.get(stored, region) || %RegionState{space_id: space.id, region: region}
    end)
  end

  def get_state(%Space{} = space, region) when is_binary(region) do
    Repo.get_by(RegionState, space_id: space.id, region: region)
  end

  @doc false
  def ensure_state(%Space{} = space, region) when is_binary(region) do
    case get_state(space, region) do
      %RegionState{} = state ->
        state

      nil ->
        %RegionState{space_id: space.id, region: region}
        |> RegionState.changeset(%{})
        |> Repo.insert!(
          on_conflict: {:replace, [:updated_at]},
          conflict_target: [:space_id, :region],
          returning: true
        )
    end
  end

  @doc false
  def update_state(%Space{} = space, region, attrs) when is_binary(region) and is_map(attrs) do
    state =
      space
      |> ensure_state(region)
      |> RegionState.changeset(attrs)
      |> Repo.update!()

    Events.broadcast_updated(space.id)
    state
  end

  defp reset_sync_state(space, region) do
    update_state(space, region, %{
      sync_status: "pending",
      sync_error: nil,
      synced_at: nil,
      objects_pending: 0
    })
  end

  defp synced?(space, region) do
    match?(%RegionState{synced_at: %DateTime{}}, get_state(space, region))
  end

  defp update_space(%Space{} = space, attrs) do
    with {:ok, updated} <- space |> Space.multi_region_changeset(attrs) |> Repo.update() do
      Cache.delete({:replicated, updated.id})
      Cache.delete_matching(:delivery)
      Events.broadcast_updated(updated.id)
      {:ok, updated}
    end
  end

  # Deployments with a CDN that selects its own origin can follow delivery
  # changes here, for example to switch a load-balancer pool or DNS record.
  defp notify_router(space, from, to, reason) do
    result =
      case Application.get_env(:mave_core, :multi_region_delivery_router) do
        nil -> :ok
        fun when is_function(fun, 4) -> fun.(space, from, to, reason)
        module when is_atom(module) -> module.delivery_region_changed(space, from, to, reason)
      end

    case result do
      {:error, error} ->
        Logger.warning(
          "Delivery router failed for space #{space.hash} (#{from} -> #{to}): #{inspect(error)}"
        )

      _other ->
        :ok
    end
  end
end
