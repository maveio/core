defmodule MaveCore.MultiRegionTest do
  use MaveCore.DataCase, async: false

  alias MaveCore.Accounts
  alias MaveCore.Embeds.Embed
  alias MaveCore.Media.Storage
  alias MaveCore.MultiRegion
  alias MaveCore.MultiRegion.{Delivery, Health, Replicator}
  alias MaveCore.Spaces.Space
  alias MaveCore.Workers.MultiRegionSyncWorker

  @moduletag :integration

  # A second bucket prefix on the test object store stands in for another region.
  @replica "replica"

  setup do
    s3 = Application.get_env(:mave_core, :s3)

    put_env(:storage_providers, %{
      @replica =>
        Keyword.merge(s3,
          bucket_prefix: "replica-",
          public_base_url: "https://replica.example.test"
        )
    })

    put_env(:multi_region,
      failure_threshold: 2,
      probe_retry_delay_ms: 0,
      recovery_threshold: 2
    )

    {:ok, owner} =
      Accounts.create_user("multi-region-#{System.unique_integer([:positive])}@example.com")

    space = owner.current_space_membership.space
    primary = MultiRegion.primary_region(space)

    bucket = Storage.bucket_for_space(space.hash, primary)
    replica_bucket = Storage.bucket_for_space(space.hash, @replica)
    :ok = Storage.ensure_bucket(bucket, primary)

    on_exit(fn ->
      Storage.delete_prefix(bucket, "", primary)
      Storage.delete_prefix(replica_bucket, "", @replica)
    end)

    %{space: space, primary: primary, bucket: bucket, replica_bucket: replica_bucket}
  end

  describe "regions" do
    test "offers configured profiles that use another bucket", %{space: space, primary: primary} do
      # Same store and same bucket prefix as the primary: not a second copy.
      put_env(
        :storage_providers,
        Map.put(
          Application.get_env(:mave_core, :storage_providers),
          "alias",
          Application.get_env(:mave_core, :s3)
        )
      )

      assert MultiRegion.selectable_regions(space) == [@replica]
      assert MultiRegion.available?(space)
      assert MultiRegion.regions(space) == [primary]
      assert {:error, :unknown_region} = MultiRegion.add_region(space, "alias")
      assert {:error, :unknown_region} = MultiRegion.add_region(space, "nowhere")
    end

    test "the host can withhold multi-region delivery", %{space: space} do
      put_env(:usage_limits_backend, __MODULE__.NoMultiRegion)

      refute MultiRegion.available?(space)
      assert {:error, :plan_required} = MultiRegion.add_region(space, @replica)
    end
  end

  describe "replication" do
    test "copies public media, keeps the replica current and removes what left the primary",
         ctx do
      embed(ctx.space, "pub01")
      put(ctx, "pub01/playlist.m3u8", "#EXTM3U v1")
      put(ctx, "pub01/h264/segment_1.ts", "media")

      assert {:ok, space} = MultiRegion.add_region(ctx.space, @replica)
      assert MultiRegion.regions(space) == [ctx.primary, @replica]

      assert replica_keys(ctx) == ["pub01/h264/segment_1.ts", "pub01/playlist.m3u8"]
      assert replica_body(ctx, "pub01/playlist.m3u8") == "#EXTM3U v1"

      assert %{sync_status: "synced", objects_total: 2, last_copied: 2, synced_at: %DateTime{}} =
               MultiRegion.get_state(space, @replica)

      # Same size, new content.
      put(ctx, "pub01/playlist.m3u8", "#EXTM3U v2")
      :ok = Storage.delete_object(ctx.bucket, "pub01/h264/segment_1.ts", ctx.primary)

      assert {:ok, %{copied: 1, deleted: 1, objects: 1}} = Replicator.sync(space, @replica)
      assert replica_keys(ctx) == ["pub01/playlist.m3u8"]
      assert replica_body(ctx, "pub01/playlist.m3u8") == "#EXTM3U v2"

      assert {:ok, %{copied: 0, deleted: 0}} = Replicator.sync(space, @replica)
    end

    test "never copies media of private, deleted or unknown embeds", ctx do
      embed(ctx.space, "pub01")
      embed(ctx.space, "priv1", playback_visibility: :private, playback_status: :private)
      embed(ctx.space, "going", playback_status: :protecting)
      embed(ctx.space, "gone1", deleted_at: DateTime.utc_now())

      for hash <- ~w(pub01 priv1 going gone1 stray), do: put(ctx, hash <> "/manifest.json", "{}")

      assert {:ok, space} = MultiRegion.add_region(ctx.space, @replica)
      assert replica_keys(ctx) == ["pub01/manifest.json"]

      # An embed that turns private leaves the replica on the next pass.
      Repo.update_all(from(e in Embed, where: e.hash == "pub01"),
        set: [playback_status: :protecting]
      )

      assert {:ok, %{deleted: 1, objects: 0}} = Replicator.sync(space, @replica)
      assert replica_keys(ctx) == []
    end

    test "an embed change replicates that embed without a full pass", ctx do
      pub = embed(ctx.space, "pub01")
      other = embed(ctx.space, "pub02")
      assert {:ok, space} = MultiRegion.add_region(ctx.space, @replica)

      put(ctx, "pub01/manifest.json", "{}")
      put(ctx, "pub02/manifest.json", "{}")

      assert :ok = MultiRegion.embed_changed(space.id, pub.id)
      assert replica_keys(ctx) == ["pub01/manifest.json"]

      assert :ok = MultiRegion.embed_changed(space.id, other.id)
      assert replica_keys(ctx) == ["pub01/manifest.json", "pub02/manifest.json"]
    end

    test "removing an embed from replicas is immediate", ctx do
      embed(ctx.space, "pub01")
      embed(ctx.space, "pub02")
      put(ctx, "pub01/manifest.json", "{}")
      put(ctx, "pub02/manifest.json", "{}")
      assert {:ok, space} = MultiRegion.add_region(ctx.space, @replica)

      assert :ok = Replicator.remove_embed(space, "pub01")
      assert replica_keys(ctx) == ["pub02/manifest.json"]
    end

    test "removing a region deletes its copy and returns delivery to the primary", ctx do
      embed(ctx.space, "pub01")
      put(ctx, "pub01/manifest.json", "{}")
      assert {:ok, space} = MultiRegion.add_region(ctx.space, @replica)
      assert {:ok, space} = MultiRegion.set_delivery_region(space, @replica)
      assert MultiRegion.delivery_region(space) == @replica

      assert {:ok, space} = MultiRegion.remove_region(space, @replica)

      assert MultiRegion.regions(space) == [ctx.primary]
      assert MultiRegion.delivery_region(space) == ctx.primary
      assert replica_keys(ctx) == []
      assert Storage.exists?(ctx.bucket, "pub01/manifest.json", ctx.primary)
      assert MultiRegion.list_replicated_spaces() == []
    end

    test "refuses a replica that is the primary bucket", ctx do
      assert {:error, :replica_is_primary_bucket} = Replicator.sync(ctx.space, ctx.primary)
      assert {:error, :replica_is_primary_bucket} = Replicator.purge(ctx.space, ctx.primary)
    end

    test "a full pass is due after the reconcile interval", ctx do
      assert {:ok, space} = MultiRegion.add_region(ctx.space, @replica)
      state = MultiRegion.get_state(space, @replica)

      refute MultiRegionSyncWorker.due?(state, DateTime.utc_now())
      assert MultiRegionSyncWorker.due?(state, DateTime.add(DateTime.utc_now(), 3600))
      assert MultiRegionSyncWorker.due?(%{state | sync_status: "failed"}, DateTime.utc_now())
    end
  end

  describe "failover" do
    setup ctx do
      {:ok, space} = MultiRegion.add_region(ctx.space, @replica)
      health = start_supervised!({Agent, fn -> %{} end})

      put_env(:multi_region_health_check, fn region, _bucket ->
        Agent.get(health, &Map.get(&1, region, :ok))
      end)

      %{space: space, health: health}
    end

    test "moves delivery to a synced replica and back once the primary recovered", ctx do
      down(ctx, ctx.primary)
      check(ctx)

      assert %Space{delivery_region: @replica, delivery_region_reason: "failover"} = reload(ctx)

      assert %{health: "unavailable", health_error: "storage answered with HTTP 503"} =
               MultiRegion.get_state(ctx.space, ctx.primary)

      # One good check is not a recovery yet.
      up(ctx, ctx.primary)
      check(ctx)
      assert MultiRegion.delivery_region(reload(ctx)) == @replica
      assert %{health: "unavailable"} = MultiRegion.get_state(ctx.space, ctx.primary)

      check(ctx)
      assert %Space{delivery_region: nil, delivery_region_reason: "recovered"} = reload(ctx)

      assert %{health: "healthy", health_error: nil} =
               MultiRegion.get_state(ctx.space, ctx.primary)
    end

    test "tells the delivery router about each move", ctx do
      test = self()

      put_env(:multi_region_delivery_router, fn space, from, to, reason ->
        send(test, {:routed, space.hash, from, to, reason})
        :ok
      end)

      down(ctx, ctx.primary)
      check(ctx)

      assert_received {:routed, hash, from, @replica, "failover"}
      assert hash == ctx.space.hash
      assert from == ctx.primary
    end

    test "stays put in manual mode", ctx do
      {:ok, _space} = MultiRegion.set_failover_mode(ctx.space, "manual")
      down(ctx, ctx.primary)
      check(ctx)

      assert MultiRegion.delivery_region(reload(ctx)) == ctx.primary
      assert %{health: "unavailable"} = MultiRegion.get_state(ctx.space, ctx.primary)
    end

    test "a manual choice is kept until that region fails", ctx do
      {:ok, _space} = MultiRegion.set_delivery_region(ctx.space, @replica)
      check(ctx)
      assert MultiRegion.delivery_region(reload(ctx)) == @replica

      down(ctx, @replica)
      check(ctx)
      assert %Space{delivery_region: nil, delivery_region_reason: "failover"} = reload(ctx)
    end

    test "a replica without a complete copy cannot take over", ctx do
      Repo.update_all(MaveCore.MultiRegion.RegionState,
        set: [synced_at: nil, sync_status: "pending"]
      )

      down(ctx, ctx.primary)
      check(ctx)

      assert MultiRegion.delivery_region(reload(ctx)) == ctx.primary
      assert {:error, :region_not_synced} = MultiRegion.set_delivery_region(reload(ctx), @replica)
    end

    test "replication waits while the primary is down", ctx do
      down(ctx, ctx.primary)
      check(ctx)

      assert {:snooze, 60} =
               MultiRegionSyncWorker.perform(%Oban.Job{
                 args: %{"space_id" => ctx.space.id, "region" => @replica, "action" => "sync"}
               })

      assert %{sync_status: "synced"} = MultiRegion.get_state(ctx.space, @replica)
    end
  end

  describe "delivery" do
    test "media URLs follow the serving region", ctx do
      embed(ctx.space, "pub01")
      assert {:ok, space} = MultiRegion.add_region(ctx.space, @replica)

      primary_url = Delivery.object_url(space, "pub01/manifest.json")

      assert primary_url ==
               "#{Application.get_env(:mave_core, :s3)[:endpoint]}/#{ctx.bucket}/pub01/manifest.json"

      assert {:ok, bucket_url} = Delivery.resolve("space-" <> space.hash)
      assert bucket_url <> "/pub01/manifest.json" == primary_url

      assert {:ok, space} = MultiRegion.set_delivery_region(space, @replica)

      assert Delivery.object_url(space, "pub01/manifest.json") ==
               "https://replica.example.test/#{ctx.replica_bucket}/pub01/manifest.json"

      assert {:ok, "https://replica.example.test/" <> _bucket} =
               Delivery.resolve("space-" <> space.hash)

      assert :error = Delivery.resolve("space-zzzzz")
      assert :error = Delivery.resolve("other-" <> space.hash)
    end
  end

  defmodule NoMultiRegion do
    def can_use_multi_region?(_space), do: {:error, :plan_required}
  end

  defp embed(space, hash, attrs \\ []) do
    Repo.insert!(struct(%Embed{space_id: space.id, hash: hash, type: :video}, attrs))
  end

  defp put(ctx, key, body) do
    {:ok, _response} =
      Storage.put_public(ctx.bucket, key, body, "application/octet-stream", ctx.primary)
  end

  defp replica_keys(ctx) do
    {:ok, keys} = Storage.list_keys(ctx.replica_bucket, "", @replica)
    Enum.sort(keys)
  end

  defp replica_body(ctx, key) do
    {:ok, body} = Storage.get(ctx.replica_bucket, key, @replica)
    body
  end

  defp down(ctx, region),
    do: Agent.update(ctx.health, &Map.put(&1, region, {:error, {:bucket_probe_failed, 503}}))

  defp up(ctx, region), do: Agent.update(ctx.health, &Map.delete(&1, region))
  defp check(ctx), do: Health.check([reload(ctx)])
  defp reload(ctx), do: Repo.get!(Space, ctx.space.id)

  defp put_env(key, value) do
    previous = Application.fetch_env(:mave_core, key)
    Application.put_env(:mave_core, key, value)

    on_exit(fn ->
      case previous do
        {:ok, value} -> Application.put_env(:mave_core, key, value)
        :error -> Application.delete_env(:mave_core, key)
      end
    end)
  end
end
