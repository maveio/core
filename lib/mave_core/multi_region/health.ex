defmodule MaveCore.MultiRegion.Health do
  @moduledoc """
  Region health checks and the failover decision that follows from them.

  A region is checked through its storage API. One failed probe is confirmed
  with further probes before the region counts as unavailable, and a region that
  was unavailable has to pass several checks before it serves viewers again.
  """
  require Logger

  alias MaveCore.Media.Storage
  alias MaveCore.MultiRegion
  alias MaveCore.MultiRegion.RegionState
  alias MaveCore.Spaces.Space

  @doc """
  Probes every region used by `spaces` once and applies the result to each
  space: region states are updated and delivery moves when the serving region
  became unavailable or the primary recovered.
  """
  @spec check([Space.t()]) :: :ok
  def check(spaces) when is_list(spaces) do
    results = probe_regions(spaces)

    Enum.each(spaces, fn space ->
      states =
        Enum.map(MultiRegion.regions(space), fn region ->
          record(space, region, Map.fetch!(results, region))
        end)

      evaluate(space, states)
    end)
  end

  # An outage is regional, so one bucket per region stands in for the others.
  defp probe_regions(spaces) do
    spaces
    |> Enum.flat_map(fn space ->
      Enum.map(MultiRegion.regions(space), fn region ->
        {region, Storage.bucket_for_space(space.hash, region)}
      end)
    end)
    |> Enum.uniq_by(fn {region, _bucket} -> region end)
    |> Task.async_stream(fn {region, bucket} -> {region, probe(region, bucket, 1)} end,
      max_concurrency: 8,
      ordered: false,
      timeout: :infinity
    )
    |> Map.new(fn {:ok, result} -> result end)
  end

  defp probe(region, bucket, attempt) do
    case run_probe(region, bucket) do
      :ok ->
        :ok

      {:error, reason} ->
        if attempt < MultiRegion.config(:failure_threshold) do
          Process.sleep(MultiRegion.config(:probe_retry_delay_ms))
          probe(region, bucket, attempt + 1)
        else
          {:error, reason}
        end
    end
  end

  # Deployments can replace the storage probe, for example to also test their CDN.
  defp run_probe(region, bucket) do
    case Application.get_env(:mave_core, :multi_region_health_check) do
      nil -> Storage.probe_bucket(bucket, region, MultiRegion.config(:probe_timeout_ms))
      fun when is_function(fun, 2) -> fun.(region, bucket)
      module when is_atom(module) -> module.check_region(region, bucket)
    end
  end

  defp record(space, region, result) do
    previous = MultiRegion.ensure_state(space, region)
    now = DateTime.utc_now()

    attrs =
      case result do
        :ok ->
          successes = previous.consecutive_successes + 1

          recovering? =
            previous.health == "unavailable" and
              successes < MultiRegion.config(:recovery_threshold)

          %{
            health: if(recovering?, do: "unavailable", else: "healthy"),
            health_error: if(recovering?, do: previous.health_error),
            consecutive_successes: successes
          }

        {:error, reason} ->
          %{health: "unavailable", health_error: describe(reason), consecutive_successes: 0}
      end

    attrs =
      attrs
      |> Map.put(:health_checked_at, now)
      |> then(fn attrs ->
        if attrs.health != previous.health,
          do: Map.put(attrs, :health_changed_at, now),
          else: attrs
      end)

    MultiRegion.update_state(space, region, attrs)
  end

  defp evaluate(%Space{delivery_failover: "manual"}, _states), do: :ok

  defp evaluate(%Space{} = space, states) do
    primary = MultiRegion.primary_region(space)
    serving = MultiRegion.delivery_region(space)
    health = Map.new(states, &{&1.region, &1})

    cond do
      health[serving].health == "unavailable" ->
        case Enum.find(states, &takeover_candidate?(&1, serving, primary)) do
          %RegionState{region: region} ->
            move(space, region, "failover")

          nil ->
            Logger.warning("No healthy region can take over delivery for space #{space.hash}")
        end

      serving != primary and space.delivery_region_reason == "failover" and
          health[primary].health == "healthy" ->
        move(space, primary, "recovered")

      true ->
        :ok
    end
  end

  defp takeover_candidate?(%RegionState{} = state, serving, primary) do
    # A replica qualifies once it has held a complete copy. Its latest pass may
    # have failed precisely because the primary is down.
    state.region != serving and state.health == "healthy" and
      (state.region == primary or not is_nil(state.synced_at))
  end

  defp move(space, region, reason) do
    case MultiRegion.set_delivery_region(space, region, reason) do
      {:ok, _space} ->
        :ok

      {:error, error} ->
        Logger.warning(
          "Could not move delivery for space #{space.hash} to #{region}: #{inspect(error)}"
        )
    end
  end

  defp describe({:bucket_probe_failed, status}), do: "storage answered with HTTP #{status}"
  defp describe(%{__exception__: true} = exception), do: Exception.message(exception)
  defp describe(reason), do: inspect(reason)
end
