defmodule MaveCore.Analytics.OverviewTest do
  use ExUnit.Case, async: false

  alias MaveCore.Analytics.Overview
  alias MaveCore.ClickHouseRepo

  @now ~U[2026-10-12 15:30:00Z]

  setup do
    config = Application.get_env(:mave_core, MaveCore.ClickHouseRepo)
    db_name = config[:database] || "mave_metrics"
    ClickHouseRepo.query("TRUNCATE TABLE IF EXISTS #{db_name}.events")

    {:ok, db_name: db_name}
  end

  test "window covers the period up to now and an equal period before it" do
    assert %{bucket: :day, from: ~U[2026-09-13 00:00:00Z], to: @now, buckets: buckets} =
             window = Overview.window("30d", @now)

    assert length(buckets) == 30
    assert List.last(buckets) == ~U[2026-10-12 00:00:00Z]
    assert DateTime.diff(window.from, window.previous_from) == DateTime.diff(@now, window.from)

    assert %{bucket: :hour, buckets: hours} = Overview.window("24h", @now)
    assert length(hours) == 24
    assert List.last(hours) == ~U[2026-10-12 15:00:00Z]

    assert %{bucket: :month, from: ~U[2025-11-01 00:00:00Z], buckets: months} =
             Overview.window("12m", @now)

    assert length(months) == 12
  end

  test "counts views, watch time and completion per video session", %{db_name: db_name} do
    now = DateTime.utc_now()

    insert_events(db_name, [
      # Current period: two sessions on one video, one on another.
      {-3_600, "play", 1, "AAAAAAAAAA", 0.0},
      {-3_540, "pause", 1, "AAAAAAAAAA", 60.0},
      {-1_800, "play", 2, "AAAAAAAAAA", 0.0},
      {-1_770, "pause", 2, "AAAAAAAAAA", 30.0},
      {-600, "play", 3, "BBBBBBBBBB", 0.0},
      {-480, "pause", 3, "BBBBBBBBBB", 120.0},
      # Under one second watched: not a view.
      {-300, "play", 4, "BBBBBBBBBB", 0.0},
      {-299.5, "pause", 4, "BBBBBBBBBB", 0.5},
      # Previous period (more than 24 hours ago).
      {-30 * 3_600, "play", 5, "AAAAAAAAAA", 0.0},
      {-30 * 3_600 + 12, "pause", 5, "AAAAAAAAAA", 12.0}
    ])

    assert {:ok, overview} = Overview.space_overview("space", "24h", now)

    assert overview.current.views == 3
    assert overview.current.watch_ms == 210_000
    assert overview.current.avg_watch_ms == 70_000
    # Completion: 60/120, 30/120 and 120/120.
    assert_in_delta overview.current.avg_completion, (0.5 + 0.25 + 1.0) / 3, 0.001

    assert overview.previous.views == 1
    assert overview.previous.watch_ms == 12_000

    assert length(overview.series) == 24
    assert Enum.sum(Enum.map(overview.series, & &1.views)) == 3
    assert [%{device: "desktop", views: 3}] = overview.devices
    assert [%{os: "Mac OS", views: 3}] = overview.operating_systems
    assert [%{website: "example.com", views: 3}] = overview.websites

    # Reached 50%, 25% and 100% of the video.
    assert [
             %{percent: 0, share: 1.0},
             %{percent: 25, share: 1.0},
             %{percent: 50, share: two_thirds},
             %{percent: 75, share: one_third},
             %{percent: 95, share: finished}
           ] = overview.reach

    assert_in_delta two_thirds, 2 / 3, 0.001
    assert_in_delta one_third, 1 / 3, 0.001
    assert_in_delta finished, 1 / 3, 0.001

    assert overview.hours |> Map.values() |> Enum.sum() == 3

    assert Enum.all?(Map.keys(overview.hours), fn {day, hour} -> day in 1..7 and hour in 0..23 end)
  end

  test "ranks videos with watch time, completion and views per bucket", %{db_name: db_name} do
    now = DateTime.utc_now()

    insert_events(db_name, [
      {-3_600, "play", 1, "AAAAAAAAAA", 0.0},
      {-3_540, "pause", 1, "AAAAAAAAAA", 60.0},
      {-1_800, "play", 2, "BBBBBBBBBB", 0.0},
      {-1_680, "pause", 2, "BBBBBBBBBB", 120.0},
      {-600, "play", 3, "BBBBBBBBBB", 0.0},
      {-570, "pause", 3, "BBBBBBBBBB", 30.0},
      # Outside the 7-day period.
      {-8 * 86_400, "play", 4, "AAAAAAAAAA", 0.0},
      {-8 * 86_400 + 60, "pause", 4, "AAAAAAAAAA", 60.0}
    ])

    assert {:ok, [first, second]} = Overview.top_videos("space", "7d", 25, now)

    assert %{embed_hash: "BBBBBBBBBB", views: 2, watch_ms: 150_000} = first
    assert_in_delta first.avg_completion, (1.0 + 0.25) / 2, 0.001
    assert length(first.series) == 7
    assert Enum.sum(first.series) == 2

    assert %{embed_hash: "AAAAAAAAAA", views: 1, watch_ms: 60_000} = second
  end

  test "rejects unknown periods" do
    assert {:error, :invalid_request} = Overview.space_overview("space", "5y")
    assert {:error, :invalid_request} = Overview.top_videos("space", "5y")
  end

  defp insert_events(db_name, events) do
    now = DateTime.utc_now()

    values =
      Enum.map_join(events, ",\n", fn {offset, name, session, embed_hash, video_time} ->
        timestamp =
          now |> DateTime.add(round(offset * 1000), :millisecond) |> DateTime.to_iso8601()

        session_id = "00000000-0000-0000-0000-#{String.pad_leading("#{session}", 12, "0")}"

        "(parseDateTime64BestEffort('#{timestamp}'), '#{name}', '#{session_id}', 'space', '#{embed_hash}', #{video_time}, 120, 'https://example.com/page', 'Chrome', '120', 'Mac OS', '14', 'Desktop', 'Apple')"
      end)

    {:ok, _} =
      ClickHouseRepo.query("""
      INSERT INTO #{db_name}.events
      (timestamp, name, session_id, space_hash, embed_hash, video_time, duration, source_url, browser, browser_version, os, os_version, device, device_brand)
      VALUES
      #{values}
      """)
  end
end
