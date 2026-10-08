defmodule MaveCoreWeb.Live.Dashboard.Data.IndexTest do
  use MaveCoreWeb.ConnCase, async: false

  import Phoenix.LiveViewTest

  alias MaveCore.Accounts
  alias MaveCore.ClickHouseRepo
  alias MaveCoreWeb.Dashboard.Data.Index
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

    assert html =~ "Data"
    assert html =~ "Today"
    assert html =~ "This month"
    assert html =~ "This year"
    assert html =~ "History"
    assert html =~ "Sources"
    assert html =~ "Device"
    assert html =~ "Browser"
    assert html =~ "grid grid-cols-3 gap-4 font-sans"
    refute html =~ "font-family: 'Sofia'"
  end

  test "/data formats analytics counts with dot thousands separators" do
    html =
      %{
        data_access_notice: nil,
        data_access_help: nil,
        views_today: async_ok(12_345),
        views_this_month: async_ok(67_890),
        views_this_year: async_ok(123_456),
        views_per_month:
          async_ok([
            %{count: 12_345, views: 12_345},
            %{count: 67_890, views: 67_890}
            | empty_months(10)
          ]),
        devices: async_ok([%{device: "desktop", views: 12_345}]),
        browsers: async_ok([%{browser: "chrome", views: 67_890}]),
        max_month: async_ok(100_000),
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

  test "/data renders stable, accessible placeholders while analytics load" do
    loading = AsyncResult.loading()

    html =
      %{
        data_access_notice: nil,
        data_access_help: nil,
        views_today: loading,
        views_this_month: loading,
        views_this_year: loading,
        views_per_month: loading,
        devices: loading,
        browsers: loading,
        max_month: loading,
        show_all_devices: false,
        show_all_browsers: false
      }
      |> Index.render()
      |> rendered_to_string()

    assert html =~ ~s(id="data-history-loading")
    assert html =~ ~s(id="data-device-sources-loading")
    assert html =~ ~s(id="data-browser-sources-loading")
    assert html =~ ~s(aria-label="Loading history")
    assert html =~ ~s(aria-busy="true")
    assert html =~ "data-loading-skeleton"
    refute html =~ "..."
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

  defp empty_months(count) do
    Enum.map(1..count, fn _month -> %{count: 0, views: 0} end)
  end
end
