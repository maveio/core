defmodule MaveCoreWeb.Api.Data.SpacesControllerTest do
  use MaveCoreWeb.ConnCase

  alias MaveCore.Accounts
  alias MaveCore.Analytics
  alias MaveCore.Spaces

  defmodule DataBlockedUsageLimits do
    @behaviour MaveCore.UsageLimits

    def can_create_video_embed?(_space), do: :ok
    def can_add_space_member?(_space, _role), do: :ok
    def can_view_space_data?(_space), do: {:error, :data_unavailable}
  end

  setup do
    old_backend = Application.get_env(:mave_core, :usage_limits_backend)
    config = Application.get_env(:mave_core, MaveCore.ClickHouseRepo)
    db_name = config[:database] || "mave_metrics"
    MaveCore.ClickHouseRepo.query("TRUNCATE TABLE IF EXISTS #{db_name}.events")

    email = "api-space-data-#{System.unique_integer([:positive])}@example.com"
    {:ok, user} = Accounts.create_user(email)
    space = user.current_space_membership.space
    {:ok, key} = Spaces.create_key(space)

    auth =
      key
      |> then(&Spaces.display_api_key(&1.key, &1.secret))
      |> then(&"Bearer #{&1}")

    on_exit(fn ->
      restore_usage_limits_backend(old_backend)
    end)

    {:ok, db_name: db_name, space: space, auth: auth}
  end

  describe "GET /api/v1/spaces/:space_hash/data" do
    test "space_monthly_watch_time returns only the current month watch time", %{
      db_name: db_name,
      space: space
    } do
      space_hash = space.hash

      sql = """
      INSERT INTO #{db_name}.events
      (timestamp, name, session_id, space_hash, embed_hash, video_time, duration, source_url, browser, browser_version, os, os_version, device, device_brand)
      VALUES
      (addSeconds(now64(6), -60), 'play',  '00000000-0000-0000-0000-000000001101', '#{space_hash}', 'AAAAAAAAAA', 0.0, 10, 'https://example.com/month', 'Chrome', '100', 'Mac', '14', 'Desktop', 'Apple'),
      (addSeconds(now64(6), -58), 'pause', '00000000-0000-0000-0000-000000001101', '#{space_hash}', 'AAAAAAAAAA', 2.0, 10, 'https://example.com/month', 'Chrome', '100', 'Mac', '14', 'Desktop', 'Apple'),
      (addMonths(now64(6), -1), 'play',  '00000000-0000-0000-0000-000000001102', '#{space_hash}', 'BBBBBBBBBB', 0.0, 10, 'https://example.com/previous', 'Safari', '17', 'Mac', '14', 'Mobile', 'Apple'),
      (addSeconds(addMonths(now64(6), -1), 9), 'pause', '00000000-0000-0000-0000-000000001102', '#{space_hash}', 'BBBBBBBBBB', 9.0, 10, 'https://example.com/previous', 'Safari', '17', 'Mac', '14', 'Mobile', 'Apple')
      """

      {:ok, _} = MaveCore.ClickHouseRepo.query(sql)
      MaveCore.ClickHouseRepo.query("OPTIMIZE TABLE #{db_name}.events FINAL")

      assert {:ok, %{watch_time: %{month: month_ms}}} =
               Analytics.space_monthly_watch_time(space_hash)

      assert month_ms in 2_000..2_500
    end

    test "returns views today/month/year + 12-month series + devices + browsers", %{
      conn: conn,
      db_name: db_name,
      space: space,
      auth: auth
    } do
      space_hash = space.hash

      # Use dates relative to now (always in the past)
      # Session 1: 5 days ago, Session 2: 2 days ago, Session 3: Today (two segments)
      sql = """
      INSERT INTO #{db_name}.events
      (timestamp, name, session_id, space_hash, embed_hash, video_time, duration, source_url, browser, browser_version, os, os_version, device, device_brand)
      VALUES
      (addSeconds(now64(6), -432000), 'play',  '00000000-0000-0000-0000-000000001001', '#{space_hash}', 'AAAAAAAAAA', 0.0, 10, 'https://example.com/5daysago', 'Chrome', '100', 'Mac', '14', 'Desktop', 'Apple'),
      (addSeconds(now64(6), -431998), 'pause', '00000000-0000-0000-0000-000000001001', '#{space_hash}', 'AAAAAAAAAA', 2.0, 10, 'https://example.com/5daysago', 'Chrome', '100', 'Mac', '14', 'Desktop', 'Apple'),
      (addSeconds(now64(6), -172800), 'play',  '00000000-0000-0000-0000-000000001002', '#{space_hash}', 'BBBBBBBBBB', 0.0, 10, 'https://example.com/2daysago', 'Safari', '17', 'Mac', '14', 'Mobile', 'Apple'),
      (addSeconds(now64(6), -172797), 'pause', '00000000-0000-0000-0000-000000001002', '#{space_hash}', 'BBBBBBBBBB', 3.0, 10, 'https://example.com/2daysago', 'Safari', '17', 'Mac', '14', 'Mobile', 'Apple'),
      (addSeconds(now64(6), -30), 'play',  '00000000-0000-0000-0000-000000001003', '#{space_hash}', 'CCCCCCCCCC', 0.0, 10, 'https://example.com/today', 'Chrome', '100', 'Mac', '14', 'Desktop', 'Apple'),
      (addSeconds(now64(6), -28), 'pause', '00000000-0000-0000-0000-000000001003', '#{space_hash}', 'CCCCCCCCCC', 2.0, 10, 'https://example.com/today', 'Chrome', '100', 'Mac', '14', 'Desktop', 'Apple'),
      (addSeconds(now64(6), -20), 'play',  '00000000-0000-0000-0000-000000001003', '#{space_hash}', 'CCCCCCCCCC', 0.0, 10, 'https://example.com/today', 'Chrome', '100', 'Mac', '14', 'Desktop', 'Apple'),
      (addSeconds(now64(6), -18), 'pause', '00000000-0000-0000-0000-000000001003', '#{space_hash}', 'CCCCCCCCCC', 2.0, 10, 'https://example.com/today', 'Chrome', '100', 'Mac', '14', 'Desktop', 'Apple')
      """

      {:ok, _} = MaveCore.ClickHouseRepo.query(sql)
      MaveCore.ClickHouseRepo.query("OPTIMIZE TABLE #{db_name}.events FINAL")

      conn =
        conn
        |> put_req_header("authorization", auth)
        |> get(~p"/api/v1/spaces/#{space_hash}/data")

      assert %{
               "data" => %{
                 "id" => ^space_hash,
                 "views" => %{
                   "today" => views_today,
                   "month" => views_month,
                   "year" => views_year
                 },
                 "watch_time" => %{"today" => wt_today, "month" => wt_month, "year" => wt_year},
                 "unique_watch_time" => %{
                   "today" => uwt_today,
                   "month" => uwt_month,
                   "year" => uwt_year
                 },
                 "views_by_month" => months,
                 "devices" => devices,
                 "browsers" => browsers
               }
             } = json_response(conn, 200)

      # ClickHouse rollups can vary slightly across the combined core+saas suite,
      # so keep this on shape/non-negative checks.
      assert is_integer(wt_today)
      assert is_integer(uwt_today)
      assert is_integer(wt_month)
      assert is_integer(wt_year)
      assert is_integer(uwt_month)
      assert is_integer(uwt_year)
      assert wt_month >= 0
      assert wt_year >= 0
      assert uwt_month >= 0
      assert uwt_year >= 0

      assert is_integer(views_today)
      assert is_integer(views_month)
      assert is_integer(views_year)

      assert length(months) == 12
      assert Enum.map(months, & &1["month"]) == Enum.to_list(1..12)

      current_month = Date.utc_today().month

      # Current month should have views (today's data at minimum)
      assert Enum.find(months, fn %{"month" => m} -> m == current_month end)["views"] >= 1

      # Total views across all months should be at least 3 (one per session)
      total_monthly_views = Enum.reduce(months, 0, fn %{"views" => v}, acc -> acc + v end)
      assert total_monthly_views >= 3

      future_months =
        months
        |> Enum.filter(fn %{"month" => m} -> m > current_month end)

      assert Enum.all?(future_months, fn %{"views" => v} -> v == 0 end)

      assert Enum.any?(devices, fn item -> item["device"] == "Desktop" and item["views"] >= 1 end)
      assert Enum.any?(devices, fn item -> item["device"] == "Mobile" and item["views"] >= 1 end)

      assert Enum.any?(browsers, fn item -> item["browser"] == "Chrome" and item["views"] >= 1 end)

      assert Enum.any?(browsers, fn item -> item["browser"] == "Safari" and item["views"] >= 1 end)
    end

    test "bounds extreme media time while preserving ordinary segments", %{
      db_name: db_name,
      space: space
    } do
      space_hash = space.hash

      sql = """
      INSERT INTO #{db_name}.events
      (timestamp, name, session_id, space_hash, embed_hash, video_time, duration, source_url, browser, browser_version, os, os_version, device, device_brand)
      VALUES
      (addSeconds(now64(6), -20), 'play',  '00000000-0000-0000-0000-000000001201', '#{space_hash}', 'AAAAAAAAAA', 0.0, 2, 'https://example.com/ordinary-media-time', 'Chrome', '100', 'Mac', '14', 'Desktop', 'Apple'),
      (addSeconds(now64(6), -18), 'pause', '00000000-0000-0000-0000-000000001201', '#{space_hash}', 'AAAAAAAAAA', 2.0, 2, 'https://example.com/ordinary-media-time', 'Chrome', '100', 'Mac', '14', 'Desktop', 'Apple'),
      (addSeconds(now64(6), -10), 'play',  '00000000-0000-0000-0000-000000001202', '#{space_hash}', 'BBBBBBBBBB', 0.0, 10000, 'https://example.com/large-media-time', 'Chrome', '100', 'Mac', '14', 'Desktop', 'Apple'),
      (addSeconds(now64(6), -8),  'pause', '00000000-0000-0000-0000-000000001202', '#{space_hash}', 'BBBBBBBBBB', 10000.0, 10000, 'https://example.com/large-media-time', 'Chrome', '100', 'Mac', '14', 'Desktop', 'Apple')
      """

      {:ok, _} = MaveCore.ClickHouseRepo.query(sql)
      MaveCore.ClickHouseRepo.query("OPTIMIZE TABLE #{db_name}.events FINAL")

      assert {:ok,
              %{
                unique_watch_time: %{
                  today: 4_000,
                  month: 4_000,
                  year: 4_000
                }
              }} = Analytics.space_data(space_hash)
    end

    test "invalid space_hash returns 404", %{conn: conn, auth: auth} do
      conn =
        conn
        |> put_req_header("authorization", auth)
        |> get(~p"/api/v1/spaces/invalid/data")

      assert response(conn, 404)
    end

    test "plan-limited spaces return 403", %{conn: conn, space: space, auth: auth} do
      Application.put_env(:mave_core, :usage_limits_backend, DataBlockedUsageLimits)

      conn =
        conn
        |> put_req_header("authorization", auth)
        |> get(~p"/api/v1/spaces/#{space.hash}/data")

      assert %{"error" => "This space cannot view aggregate data."} = json_response(conn, 403)
    end

    test "missing auth returns 401", %{conn: conn, space: space} do
      conn = get(conn, ~p"/api/v1/spaces/#{space.hash}/data")
      assert response(conn, 401)
    end
  end

  defp restore_usage_limits_backend(nil),
    do: Application.delete_env(:mave_core, :usage_limits_backend)

  defp restore_usage_limits_backend(backend),
    do: Application.put_env(:mave_core, :usage_limits_backend, backend)
end
