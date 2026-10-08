defmodule MaveCore.AnalyticsTest do
  use ExUnit.Case, async: false

  alias MaveCore.Analytics
  alias MaveCore.ClickHouseRepo

  setup do
    config = Application.get_env(:mave_core, MaveCore.ClickHouseRepo)
    db_name = config[:database] || "mave_metrics"
    ClickHouseRepo.query("TRUNCATE TABLE IF EXISTS #{db_name}.events")

    {:ok, db_name: db_name}
  end

  test "shared trial space data returns empty metrics instead of merged trial events", %{
    db_name: db_name
  } do
    sql = """
    INSERT INTO #{db_name}.events
    (timestamp, name, session_id, space_hash, embed_hash, video_time, duration, source_url, browser, browser_version, os, os_version, device, device_brand)
    VALUES
    (addSeconds(now64(6), -30), 'play',  '00000000-0000-0000-0000-000000009001', 'trial', 'AAAAAAAAAA', 0.0, 10, 'https://example.com/a', 'Chrome', '100', 'Mac', '14', 'Desktop', 'Apple'),
    (addSeconds(now64(6), -28), 'pause', '00000000-0000-0000-0000-000000009001', 'trial', 'AAAAAAAAAA', 2.0, 10, 'https://example.com/a', 'Chrome', '100', 'Mac', '14', 'Desktop', 'Apple'),
    (addSeconds(now64(6), -20), 'play',  '00000000-0000-0000-0000-000000009002', 'trial', 'BBBBBBBBBB', 0.0, 10, 'https://example.com/b', 'Safari', '17', 'Mac', '14', 'Mobile', 'Apple'),
    (addSeconds(now64(6), -18), 'pause', '00000000-0000-0000-0000-000000009002', 'trial', 'BBBBBBBBBB', 2.0, 10, 'https://example.com/b', 'Safari', '17', 'Mac', '14', 'Mobile', 'Apple')
    """

    {:ok, _} = ClickHouseRepo.query(sql)
    ClickHouseRepo.query("OPTIMIZE TABLE #{db_name}.events FINAL")

    assert {:ok,
            %{
              id: "trial",
              views: %{today: 0, month: 0, year: 0},
              watch_time: %{today: 0, month: 0, year: 0},
              unique_watch_time: %{today: 0, month: 0, year: 0},
              views_by_month: months,
              devices: [],
              browsers: []
            }} = Analytics.space_data("trial")

    assert Enum.all?(months, &(&1.views == 0))

    assert {:ok, %{watch_time: %{month: 0}}} = Analytics.space_monthly_watch_time("trial")
  end
end
