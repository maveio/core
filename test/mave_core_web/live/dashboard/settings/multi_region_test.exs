defmodule MaveCoreWeb.Live.Dashboard.Settings.MultiRegionTest do
  use MaveCoreWeb.ConnCase, async: false

  import Phoenix.LiveViewTest

  alias MaveCore.{Accounts, MultiRegion, Repo}
  alias MaveCore.MultiRegion.RegionState
  alias MaveCore.Spaces.Space

  @replica "replica"

  # Replication itself is covered against real storage in MaveCore.MultiRegionTest.
  defmodule Storage do
    def ensure_bucket(_bucket, _region), do: :ok
    def list_objects(_bucket, _prefix, _region), do: {:ok, %{}}
    def delete_prefix(_bucket, _prefix, _region), do: :ok
  end

  setup %{conn: conn} do
    put_env(:multi_region_storage, Storage)
    put_env(:bucket_cors_syncer, fn _space -> :ok end)

    put_env(:storage_providers, %{
      @replica => Keyword.merge(Application.get_env(:mave_core, :s3), bucket_prefix: "replica-")
    })

    put_env(:extra_dashboard_regions, [
      [id: @replica, name: "AMS", provider: "Example Cloud", location: "Amsterdam, NL"]
    ])

    {:ok, user} =
      Accounts.create_user("multi-region-ui-#{System.unique_integer([:positive])}@example.com")

    login_token = Accounts.generate_user_login_token(user)
    {:ok, {user, login_token}} = Accounts.login_user(login_token)

    conn =
      init_test_session(conn, user_token: Accounts.generate_user_session_token(login_token, user))

    %{conn: conn, space: user.current_space_membership.space}
  end

  test "a single configured region shows no multi-region controls", %{conn: conn} do
    put_env(:storage_providers, %{})

    {:ok, view, _html} = live(conn, "/settings")

    assert has_element?(view, "div", "current region")
    refute has_element?(view, "#multi-region")
  end

  test "adding a region replicates to it and removing it stops delivery there",
       %{conn: conn, space: space} do
    {:ok, view, _html} = live(conn, "/settings")

    assert has_element?(view, "#multi-region-status-#{@replica}", "Not in use")
    refute has_element?(view, "#multi-region-failover-row")

    view |> element("#multi-region-add-#{@replica}") |> render_click()

    assert reload(space).replica_regions == [@replica]
    assert has_element?(view, "#multi-region-status-#{@replica}", "Replica · in sync")
    assert has_element?(view, "#multi-region-detail-#{@replica}", "0 files")
    assert has_element?(view, "#multi-region-serving-#{MultiRegion.primary_region(space)}")
    assert has_element?(view, "#multi-region-failover-row")

    view |> element("#multi-region-serve-#{@replica}") |> render_click()

    assert %Space{delivery_region: @replica, delivery_region_reason: "manual"} = reload(space)
    assert has_element?(view, "#multi-region-serving-#{@replica}")

    view |> element("#multi-region-failover-toggle") |> render_click()
    assert reload(space).delivery_failover == "manual"

    view |> element("#multi-region-remove-#{@replica}") |> render_click()

    assert %Space{replica_regions: [], delivery_region: nil} = reload(space)
    assert has_element?(view, "#multi-region-status-#{@replica}", "Not in use")
  end

  test "shows an unavailable region and where viewers are served from",
       %{conn: conn, space: space} do
    {:ok, space} = MultiRegion.add_region(space, @replica)
    primary = MultiRegion.primary_region(space)

    MultiRegion.update_state(space, primary, %{
      health: "unavailable",
      health_error: "storage answered with HTTP 503",
      health_changed_at: DateTime.utc_now()
    })

    {:ok, _space} = MultiRegion.set_delivery_region(space, @replica, "failover")

    {:ok, view, _html} = live(conn, "/settings")

    assert has_element?(view, "#multi-region-status-#{primary}", "Primary · unavailable")
    assert has_element?(view, "#multi-region-detail-#{primary}", "HTTP 503")
    assert has_element?(view, "#multi-region-row-#{primary} [data-health=unavailable]")
    assert has_element?(view, "#multi-region-serving-#{@replica}")
    refute has_element?(view, "#multi-region-serving-#{primary}")
    refute has_element?(view, "#multi-region-serve-#{primary}")
    assert has_element?(view, "#multi-region-notice", "Viewers moved to AMS")

    # Reachable again, but one good check is not a recovery yet.
    MultiRegion.update_state(space, primary, %{consecutive_successes: 1})

    assert has_element?(view, "#multi-region-status-#{primary}", "Primary · recovering")
  end

  test "a replica without a complete copy cannot serve yet", %{conn: conn, space: space} do
    {:ok, _space} = MultiRegion.add_region(space, @replica)
    Repo.update_all(RegionState, set: [synced_at: nil, sync_status: "pending"])

    {:ok, view, _html} = live(conn, "/settings")

    assert has_element?(view, "#multi-region-status-#{@replica}", "waiting for first copy")
    refute has_element?(view, "#multi-region-serve-#{@replica}")
  end

  defp reload(space), do: Repo.get!(Space, space.id)

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
