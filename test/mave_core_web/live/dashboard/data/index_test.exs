defmodule MaveCoreWeb.Live.Dashboard.Data.IndexTest do
  use MaveCoreWeb.ConnCase, async: false

  import Phoenix.LiveViewTest

  alias MaveCore.Accounts
  alias MaveCore.Analytics.Overview
  alias MaveCore.ClickHouseRepo
  alias MaveCore.Embeds
  alias MaveCore.Repo
  alias MaveCoreWeb.Dashboard.Data.Index
  alias MaveCoreWeb.Dashboard.Data.OverviewComponents
  alias Phoenix.LiveView.AsyncResult

  setup do
    config = Application.get_env(:mave_core, MaveCore.ClickHouseRepo)
    db_name = config[:database] || "mave_metrics"
    ClickHouseRepo.query("TRUNCATE TABLE IF EXISTS #{db_name}.events")

    {:ok, db_name: db_name}
  end

  test "/data renders space analytics from clickhouse", %{conn: conn, db_name: db_name} do
    {conn, space} = authenticated_conn(conn)

    sql = """
    INSERT INTO #{db_name}.events
    (timestamp, name, session_id, space_hash, embed_hash, video_time, duration, source_url, browser, browser_version, os, os_version, device, device_brand)
    VALUES
    (addSeconds(now64(6), -172800), 'play',  '00000000-0000-0000-0000-000000001002', '#{space.hash}', 'BBBBBBBBBB', 0.0, 10, 'https://example.com/2daysago', 'Safari', '17', 'Mac', '14', 'Mobile', 'Apple'),
    (addSeconds(now64(6), -172797), 'pause', '00000000-0000-0000-0000-000000001002', '#{space.hash}', 'BBBBBBBBBB', 3.0, 10, 'https://example.com/2daysago', 'Safari', '17', 'Mac', '14', 'Mobile', 'Apple'),
    (addSeconds(now64(6), -30), 'play',  '00000000-0000-0000-0000-000000001003', '#{space.hash}', 'CCCCCCCCCC', 0.0, 10, 'https://example.com/today', 'Chrome', '100', 'Mac', '14', 'Desktop', 'Apple'),
    (addSeconds(now64(6), -28), 'pause', '00000000-0000-0000-0000-000000001003', '#{space.hash}', 'CCCCCCCCCC', 2.0, 10, 'https://example.com/today', 'Chrome', '100', 'Mac', '14', 'Desktop', 'Apple')
    """

    {:ok, _} = ClickHouseRepo.query(sql)
    ClickHouseRepo.query("OPTIMIZE TABLE #{db_name}.events FINAL")

    {:ok, view, _html} = live(conn, "/data")
    # Real ClickHouse queries can exceed the default 100 ms on a cold test stack.
    _ = render_async(view, 5_000)
    html = render(view)

    assert html =~ "Views"
    assert html =~ "Watch time"
    assert html =~ "Average per view"
    assert html =~ "Average completion"
    assert html =~ "History"
    assert html =~ "Sources"
    assert html =~ "Device"
    assert html =~ "Browser"
    assert has_element?(view, "#data-trend .w-1")
    assert has_element?(view, "#data-trend .bg-blue-500")
    refute has_element?(view, "#data-trend svg")
    # The default calendar month includes both views.
    assert view |> element("#data-kpis") |> render() =~ ~r/>\s*2\s*</
    refute html =~ "font-family: 'Sofia'"
  end

  test "/data switches period and compares with the previous period", %{
    conn: conn,
    db_name: db_name
  } do
    {conn, space} = authenticated_conn(conn)

    sql = """
    INSERT INTO #{db_name}.events
    (timestamp, name, session_id, space_hash, embed_hash, video_time, duration, source_url, browser, browser_version, os, os_version, device, device_brand)
    VALUES
    (addSeconds(now64(6), -108000), 'play',  '00000000-0000-0000-0000-000000001102', '#{space.hash}', 'BBBBBBBBBB', 0.0, 10, 'https://example.com/a', 'Safari', '17', 'Mac', '14', 'Mobile', 'Apple'),
    (addSeconds(now64(6), -107997), 'pause', '00000000-0000-0000-0000-000000001102', '#{space.hash}', 'BBBBBBBBBB', 3.0, 10, 'https://example.com/a', 'Safari', '17', 'Mac', '14', 'Mobile', 'Apple'),
    (addSeconds(now64(6), -30), 'play',  '00000000-0000-0000-0000-000000001103', '#{space.hash}', 'CCCCCCCCCC', 0.0, 10, 'https://example.com/b', 'Chrome', '100', 'Mac', '14', 'Desktop', 'Apple'),
    (addSeconds(now64(6), -28), 'pause', '00000000-0000-0000-0000-000000001103', '#{space.hash}', 'CCCCCCCCCC', 2.0, 10, 'https://example.com/b', 'Chrome', '100', 'Mac', '14', 'Desktop', 'Apple')
    """

    {:ok, _} = ClickHouseRepo.query(sql)

    {:ok, view, _html} = live(conn, "/data")
    _ = render_async(view, 5_000)

    view |> element(~s(#data-period-switch a[href="/data?period=today"])) |> render_click()
    assert_patch(view, "/data?period=today")
    _ = render_async(view, 5_000)

    kpis = view |> element("#data-kpis") |> render()
    # One view today against one in the elapsed part of yesterday.
    assert kpis =~ ~s(title="vs yesterday at the same time")
    assert kpis =~ "± 0,0%"
    assert has_element?(view, ~s(#data-period-switch a[aria-current="page"]), "Today")
    assert has_element?(view, ~s(a[href="/data/top?period=today"]))
  end

  test "/data formats analytics counts with dot thousands separators" do
    html =
      %{
        live_action: :index,
        route_scope: :unscoped,
        current_space: %{id: "space-id"},
        period: "month",
        data_access_notice: nil,
        analytics_preparing: false,
        data_access_help: nil,
        overview:
          async_ok(%{
            Overview.empty("month")
            | current: %{views: 123_456, watch_ms: 0, avg_watch_ms: 0, avg_completion: 0.0},
              devices: [%{device: "desktop", views: 12_345}],
              browsers: [%{browser: "chrome", views: 67_890}]
          }),
        show_all_devices: false,
        show_all_browsers: false
      }
      |> Index.render()
      |> rendered_to_string()

    assert html =~ "12.345"
    assert html =~ "67.890"
    assert html =~ "123.456"
    refute html =~ "12345"
    refute html =~ "67890"
    refute html =~ "123456"
  end

  test "empty periods do not display negative comparisons" do
    previous = %{views: 10, watch_ms: 60_000, avg_watch_ms: 6_000, avg_completion: 0.5}
    current = %{views: 0, watch_ms: 0, avg_watch_ms: 0, avg_completion: 0.0}

    html =
      render_component(&OverviewComponents.kpis/1,
        overview: async_ok(%{current: current, previous: previous}),
        period: "month"
      )

    refute html =~ "data-metric-delta"

    html =
      render_component(&OverviewComponents.kpis/1,
        overview:
          async_ok(%{
            current: %{
              current
              | views: 5,
                watch_ms: 30_000,
                avg_watch_ms: 6_000,
                avg_completion: 0.25
            },
            previous: previous
          }),
        period: "month"
      )

    assert html =~ "▼ 50,0%"
    assert html =~ "data-metric-delta"
  end

  test "history uses consistent interactive bars for every period" do
    for {period, count} <- [{"today", 24}, {"week", 7}, {"month", 31}, {"year", 12}] do
      overview = Overview.empty(period, ~U[2026-10-26 12:00:00Z])

      overview = %{
        overview
        | series: Enum.map(overview.series, &%{&1 | views: 123_456, watch_ms: 5_400_000})
      }

      html =
        render_component(&OverviewComponents.trend/1,
          overview: async_ok(overview),
          period: period
        )

      dom = LazyHTML.from_document(html)
      assert Enum.count(LazyHTML.query(dom, "#data-trend button")) == count
      labels = Enum.count(LazyHTML.query(dom, "#data-trend-axis > span"))
      if count <= 12, do: assert(labels == count), else: assert(labels in 4..6)
      assert Enum.count(LazyHTML.query(dom, "#data-trend button[aria-label*='123.456']")) == count
      assert Enum.empty?(LazyHTML.query(dom, "#data-trend .truncate"))
      refute html =~ "Select a bar for details"
      assert Enum.count(LazyHTML.query(dom, "#data-trend-plot button")) == count
    end
  end

  test "history loading skeleton follows each selected calendar period" do
    for period <- Overview.periods() do
      expected_count = length(Overview.empty(period).series)

      html =
        render_component(&OverviewComponents.trend/1,
          overview: AsyncResult.loading(),
          period: period
        )

      dom = LazyHTML.from_document(html)

      assert Enum.count(LazyHTML.query(dom, "#data-trend-loading button[disabled]")) ==
               expected_count

      assert Enum.count(LazyHTML.query(dom, "#data-trend-plot .data-loading-skeleton")) ==
               expected_count

      assert Enum.empty?(LazyHTML.query(dom, ".data-history-tooltip"))
      assert html =~ "h-60"
      assert html =~ "Loading history"
    end
  end

  test "/data renders stable, accessible placeholders while analytics load" do
    loading = AsyncResult.loading()

    html =
      %{
        live_action: :index,
        route_scope: :unscoped,
        current_space: %{id: "space-id"},
        period: "month",
        data_access_notice: nil,
        analytics_preparing: false,
        data_access_help: nil,
        overview: loading,
        show_all_devices: false,
        show_all_browsers: false
      }
      |> Index.render()
      |> rendered_to_string()

    assert html =~ ~s(id="data-trend-loading")
    assert html =~ ~s(id="data-device-sources-loading")
    assert html =~ ~s(id="data-browser-sources-loading")
    assert html =~ ~s(aria-label="Loading history")
    assert html =~ ~s(aria-busy="true")
    assert html =~ "data-loading-skeleton"
    refute html =~ "..."
  end

  test "/data shows overview and top list tabs", %{conn: conn} do
    {conn, _space} = authenticated_conn(conn)

    {:ok, view, html} = live(conn, "/data")

    assert html =~ "Overview"
    assert html =~ "Top list"
    assert has_element?(view, ~s(a[href="/data/top"]), "Top list")

    view |> element(~s(a[href="/data/top"])) |> render_click()
    assert_patch(view, "/data/top")
  end

  test "/data/top ranks the space's videos by views", %{conn: conn, db_name: db_name} do
    {conn, space} = authenticated_conn(conn)
    {:ok, popular} = Embeds.create_video_embed(space)
    {:ok, quiet} = Embeds.create_video_embed(space)
    {:ok, deleted} = Embeds.create_video_embed(space)
    {:ok, _deleted} = Repo.update(Ecto.Changeset.change(deleted, deleted_at: DateTime.utc_now()))

    rows =
      [
        {popular.hash, 1},
        {popular.hash, 2},
        {quiet.hash, 3},
        {deleted.hash, 4},
        {deleted.hash, 5},
        {deleted.hash, 6}
      ]
      |> Enum.map_join(",\n", fn {embed_hash, session} ->
        session_id = "00000000-0000-0000-0000-00000000200#{session}"

        """
        (addSeconds(now64(6), -30), 'play', '#{session_id}', '#{space.hash}', '#{embed_hash}', 0.0, 10, 'https://example.com', 'Chrome', '100', 'Mac', '14', 'Desktop', 'Apple'),
        (addSeconds(now64(6), -27), 'pause', '#{session_id}', '#{space.hash}', '#{embed_hash}', 3.0, 10, 'https://example.com', 'Chrome', '100', 'Mac', '14', 'Desktop', 'Apple')
        """
      end)

    {:ok, _} =
      ClickHouseRepo.query("""
      INSERT INTO #{db_name}.events
      (timestamp, name, session_id, space_hash, embed_hash, video_time, duration, source_url, browser, browser_version, os, os_version, device, device_brand)
      VALUES
      #{rows}
      """)

    {:ok, view, _html} = live(conn, "/data/top")
    _ = render_async(view, 5_000)

    links =
      view
      |> render()
      |> LazyHTML.from_fragment()
      |> LazyHTML.query("#data-top-list a")
      |> Enum.map(&LazyHTML.attribute(&1, "href"))
      |> List.flatten()

    assert links == [
             "/videos/#{Embeds.dashboard_embed_id(popular)}",
             "/videos/#{Embeds.dashboard_embed_id(quiet)}"
           ]
  end

  defp authenticated_conn(conn, space_hash \\ nil) do
    email = "data-index-#{System.unique_integer([:positive])}@example.com"
    {:ok, user} = Accounts.create_user(email)
    login_token = Accounts.generate_user_login_token(user)
    {:ok, {logged_in_user, persisted_login_token}} = Accounts.login_user(login_token)
    session_token = Accounts.generate_user_session_token(persisted_login_token, logged_in_user)

    if is_binary(space_hash) do
      {:ok, created_user} = Accounts.create_space_for_user(logged_in_user, %{hash: space_hash})
      {:ok, _user} = Accounts.set_current_space_by_hash(created_user, space_hash)
    end

    refreshed_user = Accounts.get_user_by_email(email)

    conn =
      conn
      |> with_manage_host()
      |> init_test_session(user_token: session_token)

    {conn, refreshed_user.current_space_membership.space}
  end

  defp with_manage_host(conn) do
    case System.get_env("MAVE_MANAGE_HOST") do
      host when is_binary(host) and host != "" -> %{conn | host: host}
      _ -> conn
    end
  end

  defp async_ok(result), do: AsyncResult.ok(AsyncResult.loading(), result)
end
