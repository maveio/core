defmodule MaveCore.Analytics.OverviewTest do
  use MaveCore.DataCase, async: false

  alias MaveCore.Analytics.Overview
  alias MaveCore.Analytics.Sessions
  alias MaveCore.ClickHouseRepo

  @now ~U[2026-10-12 15:30:00Z]

  setup do
    previous = Application.get_env(:mave_core, :analytics_sessions)
    Application.put_env(:mave_core, :analytics_sessions, enabled: false)
    on_exit(fn -> Application.put_env(:mave_core, :analytics_sessions, previous || []) end)
    config = Application.get_env(:mave_core, MaveCore.ClickHouseRepo)
    db_name = config[:database] || "mave_metrics"
    ClickHouseRepo.query("TRUNCATE TABLE IF EXISTS #{db_name}.events")

    {:ok, db_name: db_name}
  end

  test "calendar windows include the full chart and compare elapsed periods" do
    assert %{
             bucket: :day,
             from: ~U[2026-10-01 00:00:00Z],
             to: @now,
             previous_from: ~U[2026-09-01 00:00:00Z],
             previous_to: ~U[2026-09-12 15:30:00Z],
             buckets: days
           } = Overview.window("month", @now)

    assert length(days) == 31
    assert List.last(days) == ~U[2026-10-31 00:00:00Z]

    assert %{
             from: ~U[2026-10-12 00:00:00Z],
             previous_from: ~U[2026-10-11 00:00:00Z],
             previous_to: ~U[2026-10-11 15:30:00Z],
             buckets: hours
           } = Overview.window("today", @now)

    assert length(hours) == 24
    assert List.last(hours) == ~U[2026-10-12 23:00:00Z]

    assert %{
             from: ~U[2026-10-12 00:00:00Z],
             previous_from: ~U[2026-10-05 00:00:00Z],
             previous_to: ~U[2026-10-05 15:30:00Z],
             buckets: week
           } = Overview.window("week", @now)

    assert length(week) == 7
    assert List.last(week) == ~U[2026-10-18 00:00:00Z]

    assert %{
             from: ~U[2026-01-01 00:00:00Z],
             previous_from: ~U[2025-01-01 00:00:00Z],
             previous_to: ~U[2025-10-12 15:30:00Z],
             buckets: months
           } = Overview.window("year", @now)

    assert length(months) == 12
    assert List.last(months) == ~U[2026-12-01 00:00:00Z]

    assert %{previous_to: ~U[2023-02-28 12:00:00Z]} =
             Overview.window("year", ~U[2024-02-29 12:00:00Z])

    assert %{previous_to: ~U[2026-03-01 00:00:00Z]} =
             Overview.window("month", ~U[2026-03-31 12:00:00Z])

    assert %{previous_to: ~U[2024-03-01 00:00:00Z]} =
             Overview.window("month", ~U[2024-03-31 12:00:00Z])
  end

  for period <- ~w(today week month) do
    test "#{period} excludes the unelapsed comparison and future events", %{db_name: db_name} do
      period = unquote(period)
      window = Overview.window(period, @now)

      times = [
        DateTime.add(window.from, 60),
        DateTime.add(window.previous_from, 60),
        DateTime.add(window.previous_to, 3600),
        DateTime.add(@now, 3600)
      ]

      events =
        for {at, id} <- Enum.with_index(times, 1),
            {name, seconds, position} <- [{"play", 0, 0.0}, {"pause", 3, 3.0}],
            do: {DateTime.diff(at, @now) + seconds, name, id, "AAAAAAAAAA", position}

      insert_events(db_name, events, @now)
      assert {:ok, expected} = Overview.space_overview("space", period, @now)
      assert expected.current.views == 1
      assert expected.previous.views == 1
      Application.put_env(:mave_core, :analytics_sessions, enabled: true)
      assert {:ok, 16} = Sessions.refresh_changed(space_hash: "space", limit: 16)
      assert {:ok, actual} = Overview.space_overview("space", period, @now)
      assert_overview(actual, expected)
    end
  end

  test "calendar year shows all months and compares matching year-to-date windows", %{
    db_name: db_name
  } do
    events =
      for {id, at} <- [
            {1, ~U[2026-01-10 12:00:00Z]},
            {2, ~U[2025-01-10 12:00:00Z]},
            {3, ~U[2025-11-10 12:00:00Z]},
            {4, ~U[2026-11-10 12:00:00Z]}
          ],
          {name, seconds, position} <- [{"play", 0, 0.0}, {"pause", 3, 3.0}] do
        {DateTime.diff(at, @now) + seconds, name, id, "AAAAAAAAAA", position}
      end

    insert_events(db_name, events, @now)
    assert {:ok, expected} = Overview.space_overview("space", "year", @now)
    assert expected.current.views == 1
    assert expected.previous.views == 1
    assert Enum.map(expected.series, & &1.start.month) == Enum.to_list(1..12)
    assert Enum.map(expected.series, & &1.views) == [1 | List.duplicate(0, 11)]
    Application.put_env(:mave_core, :analytics_sessions, enabled: true)
    assert {:ok, 16} = Sessions.refresh_changed(space_hash: "space", limit: 16)
    assert {:ok, actual} = Overview.space_overview("space", "year", @now)
    assert_overview(actual, expected)
  end

  test "counts views, watch time and completion per video session", %{db_name: db_name} do
    now = @now

    insert_events(
      db_name,
      [
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
      ],
      now
    )

    assert {:ok, overview} = Overview.space_overview("space", "today", now)

    assert overview.current.views == 3
    assert overview.current.watch_ms == 210_000
    assert overview.current.avg_watch_ms == 70_000
    # Completion: 60/120, 30/120 and 120/120.
    assert_in_delta overview.current.avg_completion, (0.5 + 0.25 + 1.0) / 3, 0.001

    assert overview.previous.views == 1
    assert overview.previous.watch_ms == 12_000

    assert length(overview.series) == 24
    assert Enum.sum(Enum.map(overview.series, & &1.views)) == 3
    assert [%{device: "Desktop", views: 3}] = overview.devices
  end

  test "prepared overview preserves all periods without reading raw events", %{db_name: db_name} do
    now = @now

    insert_events(
      db_name,
      [
        {-3_600, "play", 1, "AAAAAAAAAA", 0.0},
        {-3_540, "pause", 1, "AAAAAAAAAA", 60.0},
        {-1_800, "play", 2, "BBBBBBBBBB", 0.0},
        {-1_770, "pause", 2, "BBBBBBBBBB", 30.0},
        {-30 * 3_600, "play", 3, "AAAAAAAAAA", 0.0},
        {-30 * 3_600 + 12, "pause", 3, "AAAAAAAAAA", 12.0},
        {-40 * 86_400, "play", 4, "AAAAAAAAAA", 0.0},
        {-40 * 86_400 + 3, "pause", 4, "AAAAAAAAAA", 3.0},
        {-3_300, "play", 1, "AAAAAAAAAA", 0.0},
        {-3_270, "pause", 1, "AAAAAAAAAA", 30.0},
        {-1_700, "play", 2, "CCCCCCCCCC", 0.0},
        {-1_650, "pause", 2, "CCCCCCCCCC", 50.0}
      ],
      now
    )

    expected =
      Map.new(Overview.periods(), fn period ->
        {:ok, result} = Overview.space_overview("space", period, now)
        {period, result}
      end)

    Application.put_env(:mave_core, :analytics_sessions, enabled: true)
    assert {:error, :preparing} = Overview.space_overview("space", "month", now)
    assert {:ok, 16} = Sessions.refresh_changed(space_hash: "space", limit: 16)
    ClickHouseRepo.query!("TRUNCATE TABLE #{db_name}.events")

    for period <- Overview.periods() do
      assert {:ok, result} = Overview.space_overview("space", period, now)
      assert_overview(result, expected[period])
    end
  end

  test "daily summaries preserve partial-day boundaries and prepare independently", %{
    db_name: db_name
  } do
    now = @now

    insert_events(
      db_name,
      [
        {-6 * 86_400 - 15 * 3600 - 1801, "play", 1, "AAAAAAAAAA", 0.0},
        {-6 * 86_400 - 15 * 3600 - 1798, "pause", 1, "AAAAAAAAAA", 3.0},
        {-2, "play", 2, "BBBBBBBBBB", 0.0},
        {1, "pause", 2, "BBBBBBBBBB", 3.0},
        {-4, "play", 3, "CCCCCCCCCC", 0.0},
        {-2, "pause", 3, "CCCCCCCCCC", 2.0},
        {-86_400, "play", 4, "DDDDDDDDDD", 0.0},
        {-86_399.4, "pause", 4, "DDDDDDDDDD", 0.6},
        {-600, "play", 4, "DDDDDDDDDD", 0.6},
        {-599.4, "pause", 4, "DDDDDDDDDD", 1.2}
      ],
      now
    )

    expected =
      Map.new(Overview.periods(), fn period ->
        {:ok, result} = Overview.space_overview("space", period, now)
        {period, result}
      end)

    Application.put_env(:mave_core, :analytics_sessions, enabled: true)
    assert {:ok, 16} = Sessions.refresh_changed(space_hash: "space", limit: 16)

    for period <- Overview.periods() do
      assert {:ok, result} = Overview.space_overview("space", period, now)
      assert_overview(result, expected[period])
    end

    MaveCore.Repo.query!(
      "UPDATE analytics_session_buckets SET overview_ready=false WHERE space_hash='space' AND bucket=0"
    )

    assert {:ok, _} = Sessions.generations("space")
    assert {:error, :preparing} = Overview.space_overview("space", "month", now)
    assert {:ok, 1} = Sessions.refresh_changed(space_hash: "space", limit: 1)
    assert {:ok, _} = Overview.space_overview("space", "month", now)
  end

  test "a failed engagement build preserves the published generation", %{db_name: db_name} do
    insert_events(db_name, [
      {-60, "play", 1, "AAAAAAAAAA", 0.0},
      {-57, "pause", 1, "AAAAAAAAAA", 3.0}
    ])

    assert {:ok, 16} = Sessions.refresh_changed(space_hash: "space", limit: 16)
    assert {:ok, before} = Sessions.overview_generations("space")

    ClickHouseRepo.query!(
      "RENAME TABLE analytics_overview_views TO analytics_overview_views_hidden"
    )

    try do
      insert_events(db_name, [
        {-30, "play", 2, "BBBBBBBBBB", 0.0},
        {-27, "pause", 2, "BBBBBBBBBB", 3.0}
      ])

      assert {:error, {:buckets_failed, _}} =
               Sessions.refresh_changed(space_hash: "space", limit: 16)

      assert {:ok, ^before} = Sessions.overview_generations("space")
    after
      ClickHouseRepo.query!(
        "RENAME TABLE analytics_overview_views_hidden TO analytics_overview_views"
      )
    end
  end

  test "incremental refresh copies untouched session summaries", %{db_name: db_name} do
    now = @now

    events =
      for id <- 1..17,
          event <- [{-60, "play", id, "AAAAAAAAAA", 0.0}, {-57, "pause", id, "AAAAAAAAAA", 3.0}],
          do: event

    insert_events(db_name, events, now)
    Application.put_env(:mave_core, :analytics_sessions, enabled: true)
    assert {:ok, 16} = Sessions.refresh_changed(space_hash: "space", limit: 16)
    {:ok, generations} = Sessions.overview_generations("space")

    [[ids]] =
      ClickHouseRepo.query!(
        """
        SELECT groupArray(toUInt64(right(toString(session_id),12)))
        FROM analytics_overview_views WHERE space_hash='space' AND generation IN {$0:Array(UUID)}
        GROUP BY bucket HAVING count()>1 LIMIT 1
        """,
        [generations]
      ).rows

    insert_events(
      db_name,
      [{-30, "play", hd(ids), "AAAAAAAAAA", 3.0}, {-27, "pause", hd(ids), "AAAAAAAAAA", 6.0}],
      now
    )

    Application.put_env(:mave_core, :analytics_sessions, enabled: false)
    assert {:ok, expected} = Overview.space_overview("space", "today", now)
    Application.put_env(:mave_core, :analytics_sessions, enabled: true)
    assert {:ok, 1} = Sessions.refresh_changed(space_hash: "space", limit: 16)
    assert {:ok, actual} = Overview.space_overview("space", "today", now)
    assert_overview(actual, expected)
    assert actual.current.views == 17
    assert actual.current.watch_ms == 54_000
  end

  test "rejects unknown periods" do
    assert {:error, :invalid_request} = Overview.space_overview("space", "5y")
  end

  defp assert_overview(actual, expected) do
    assert Map.drop(actual, [:current, :previous]) == Map.drop(expected, [:current, :previous])

    for period <- [:current, :previous] do
      assert Map.delete(actual[period], :avg_completion) ==
               Map.delete(expected[period], :avg_completion)

      assert_in_delta actual[period].avg_completion, expected[period].avg_completion, 1.0e-12
    end
  end

  defp insert_events(db_name, events, now \\ DateTime.utc_now()) do
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
