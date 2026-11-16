defmodule MaveCoreWeb.DeliveryControllerTest do
  use MaveCoreWeb.ConnCase, async: false

  alias MaveCore.{Accounts, MultiRegion, Repo}
  alias MaveCore.MultiRegion.{Cache, RegionState}

  @replica "replica"

  setup do
    previous = Application.fetch_env(:mave_core, :storage_providers)

    Application.put_env(:mave_core, :storage_providers, %{
      @replica => [
        endpoint: "https://s3.replica.example.test",
        access_key_id: "key",
        secret_access_key: "secret",
        public_base_url: "https://{bucket}.replica.example.test"
      ]
    })

    on_exit(fn ->
      Cache.delete_matching(:delivery)

      case previous do
        {:ok, value} -> Application.put_env(:mave_core, :storage_providers, value)
        :error -> Application.delete_env(:mave_core, :storage_providers)
      end
    end)

    {:ok, user} =
      Accounts.create_user("delivery-#{System.unique_integer([:positive])}@example.com")

    %{space: user.current_space_membership.space}
  end

  test "redirects to the region that serves the space", %{conn: conn, space: space} do
    endpoint = Application.get_env(:mave_core, :s3)[:endpoint]
    path = "/delivery/space-#{space.hash}/abcde/h264/playlist.m3u8"

    conn1 = get(conn, path, %{"e" => "1"})

    assert redirected_to(conn1, 302) ==
             "#{endpoint}/space-#{space.hash}/abcde/h264/playlist.m3u8?e=1"

    assert get_resp_header(conn1, "access-control-allow-origin") == ["*"]
    assert get_resp_header(conn1, "cache-control") == ["public, max-age=30"]

    # Move delivery without running replication against the fake endpoint.
    space |> Ecto.Changeset.change(replica_regions: [@replica]) |> Repo.update!()

    Repo.insert!(%RegionState{
      space_id: space.id,
      region: @replica,
      sync_status: "synced",
      synced_at: DateTime.utc_now()
    })

    {:ok, _space} = MultiRegion.set_delivery_region(Repo.reload!(space), @replica, "failover")

    assert conn |> get(path) |> redirected_to(302) ==
             "https://space-#{space.hash}.replica.example.test/abcde/h264/playlist.m3u8"
  end

  test "answers unknown spaces and unsafe paths with 404", %{conn: conn, space: space} do
    assert conn |> get("/delivery/space-zzzzz/abcde/manifest.json") |> response(404)
    assert conn |> get("/delivery/other-#{space.hash}/abcde/manifest.json") |> response(404)
    assert conn |> get("/delivery/space-#{space.hash}/abcde/..%2Fsecret") |> response(404)
  end
end
