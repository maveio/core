defmodule MaveCore.Analytics.SessionsTest do
  use MaveCore.DataCase, async: false

  alias MaveCore.{Analytics, ClickHouseRepo, Repo}
  alias MaveCore.Analytics.Sessions
  alias MaveCore.Workers.AnalyticsSessionsWorker

  setup do
    Process.put(:analytics_time, DateTime.utc_now() |> DateTime.truncate(:second))
    old = Application.get_env(:mave_core, :analytics_sessions)
    Application.put_env(:mave_core, :analytics_sessions, enabled: false)
    ClickHouseRepo.query!("TRUNCATE TABLE events")
    ClickHouseRepo.query!("TRUNCATE TABLE analytics_sessions")
    ClickHouseRepo.query!("TRUNCATE TABLE analytics_session_years")
    ClickHouseRepo.query!("TRUNCATE TABLE analytics_session_reports")
    on_exit(fn -> Application.put_env(:mave_core, :analytics_sessions, old || []) end)
    :ok
  end

  test "prepares the legacy overview and unique-watch result without changing its values" do
    pair(1, "AAAAA", "first", 20, 25, 0, 5)
    pair(1, "AAAAA", "first", 10, 15, 2, 7)
    pair(2, "AAAAA", "other", 20, 22, 0, 2)
    pair(3, "BBBBB", "other", 20, 29, 0, 9)

    assert {:error, :preparing} = Sessions.data("AAAAA")
    assert {:ok, expected} = Analytics.space_data("AAAAA")
    assert {:ok, _} = Sessions.refresh_changed(limit: 32)
    assert {:ok, actual} = Sessions.data("AAAAA", include_unique: true)
    assert actual == expected
    assert {:ok, 0} = Sessions.refresh_changed(limit: 32)
  end

  test "bounded rounds eventually prepare all spaces without starving later buckets" do
    pair(1, "AAAAA", "first", 20, 25, 0, 5)
    pair(2, "BBBBB", "second", 20, 25, 0, 5)
    for _ <- 1..8, do: assert({:ok, 4} = Sessions.refresh_changed())
    assert {:ok, _} = Sessions.generations("AAAAA")
    assert {:ok, _} = Sessions.generations("BBBBB")
    assert {:ok, 0} = Sessions.refresh_changed()
  end

  test "a scoped backfill leaves other spaces unprepared" do
    pair(1, "AAAAA", "first", 20, 25, 0, 5)
    pair(2, "BBBBB", "second", 20, 25, 0, 5)
    assert {:ok, 16} = Sessions.refresh_changed(limit: 32, space_hash: "AAAAA")
    assert {:ok, _} = Sessions.data("AAAAA")
    assert {:error, :preparing} = Sessions.data("BBBBB")

    assert {:error, :invalid_space_hash} =
             Sessions.refresh_changed(limit: 32, space_hash: "invalid")
  end

  test "background preparation is independent of reader activation and reader scope" do
    pair(1, "AAAAA", "first", 20, 25, 0, 5)
    pair(2, "BBBBB", "second", 20, 25, 0, 5)

    Application.put_env(:mave_core, :analytics_sessions,
      enabled: false,
      processor_enabled: true,
      refresh_bucket_limit: 32
    )

    refute Sessions.enabled?("AAAAA")
    assert Sessions.processing_enabled?()
    assert :ok = AnalyticsSessionsWorker.perform(%{})
    assert {:ok, _} = Sessions.generations("AAAAA")

    Application.put_env(:mave_core, :analytics_sessions,
      enabled: true,
      processor_enabled: false,
      read_spaces: ["AAAAA"]
    )

    assert Sessions.enabled?("AAAAA")
    refute Sessions.enabled?("BBBBB")
    refute Sessions.processing_enabled?()
    Repo.query!("DELETE FROM analytics_session_buckets WHERE space_hash='BBBBB'")
    assert {:ok, %{views: %{year: 1}}} = Analytics.space_data("BBBBB")
    assert {:ok, %{views: %{year: 1}}} = Analytics.space_data("AAAAA")
  end

  test "a pause arriving first and a later historical play refresh the affected bucket" do
    event(1, "AAAAA", "video", "pause", 10, 5)
    assert {:ok, _} = Sessions.refresh_changed(limit: 32)
    assert {:ok, before} = Sessions.data("AAAAA")
    assert before.views.year == 0

    # Arrival order differs from the event timestamp order.
    event(1, "AAAAA", "video", "play", 15, 0)
    assert {:ok, 1} = Sessions.refresh_changed(limit: 32)
    assert {:ok, after_late} = Sessions.data("AAAAA")
    assert after_late.views.year == 1
    assert after_late.watch_time.year == 5_000
  end

  test "large per-video event arrays remain flattenable into a session" do
    # Nested groupArray serializes each entire video array as one element, which
    # exceeds ClickHouse's 16 MiB element limit even when total memory fits.
    ClickHouseRepo.query!("""
    INSERT INTO events (timestamp, name, session_id, space_hash, embed_hash,
      video_time, duration, source_url)
    SELECT now64(6) - INTERVAL 2048 SECOND + toIntervalSecond(number),
      if(number % 2 = 0, 'play', 'pause'),
      toUUID('00000000-0000-0000-0000-000000000001'), 'AAAAA', 'large',
      toFloat32(number % 2), 60, repeat('x', 32768)
    FROM numbers(576)
    """)

    assert {:ok, _} = Sessions.refresh_changed(limit: 32)
    assert {:ok, data} = Sessions.data("AAAAA")
    assert data.views.year == 1
    assert data.watch_time.year == 288_000

    assert ClickHouseRepo.query!(
             "SELECT source_rows, length(events), length(segments) FROM analytics_sessions"
           ).rows == [[576, 576, 288]]
  end

  test "timestamp ties preserve the raw window's playback pairing" do
    ClickHouseRepo.query!("""
    INSERT INTO events (timestamp, name, session_id, space_hash, embed_hash,
      video_time, duration)
    SELECT now64(6) - INTERVAL 2048 SECOND + toIntervalSecond(intDiv(number, 4)),
      ['play', 'pause', 'play', 'pause'][1 + number % 4],
      toUUID('00000000-0000-0000-0000-000000000001'), 'AAAAA', 'tied',
      toFloat32(number % 30), 60
    FROM numbers(1024)
    """)

    assert {:ok, expected} = Analytics.space_data("AAAAA")
    assert {:ok, _} = Sessions.refresh_changed(limit: 32)
    assert {:ok, actual} = Sessions.data("AAAAA", include_unique: true)
    assert actual == expected
  end

  test "an incremental refresh preserves unchanged session rows exactly" do
    [[other_id]] =
      ClickHouseRepo.query!("""
      SELECT number FROM numbers(2, 256)
      WHERE modulo(cityHash64(toUUID(concat('00000000-0000-0000-0000-', leftPad(toString(number),12,'0')))),16)=1
      LIMIT 1
      """).rows

    pair(1, "AAAAA", "first", 20, 25, 0, 5)
    pair(other_id, "AAAAA", "second", 20, 25, 0, 5)
    assert {:ok, _} = Sessions.refresh_changed(limit: 32)
    {:ok, before_generations} = Sessions.generations("AAAAA")

    sql =
      "SELECT events, segments, created_at FROM analytics_sessions WHERE space_hash='AAAAA' AND session_id=toUUID('00000000-0000-0000-0000-000000000001') AND generation IN {$0:Array(UUID)}"

    before = ClickHouseRepo.query!(sql, [before_generations]).rows
    pair(other_id, "AAAAA", "added", 10, 15, 0, 5)
    assert {:ok, 1} = Sessions.refresh_changed(limit: 32)
    {:ok, after_generations} = Sessions.generations("AAAAA")
    assert before == ClickHouseRepo.query!(sql, [after_generations]).rows
    assert {:ok, %{views: %{year: 2}, watch_time: %{year: 15_000}}} = Sessions.data("AAAAA")
  end

  test "a failed rebuild preserves the published generation and can be retried" do
    pair(1, "AAAAA", "video", 20, 25, 0, 5)
    assert {:ok, _} = Sessions.refresh_changed(limit: 32)
    assert {:ok, generations} = Sessions.generations("AAAAA")
    ClickHouseRepo.query!("RENAME TABLE analytics_session_years TO temporarily_unavailable_years")

    try do
      assert {:error, :analytics_unavailable} =
               Sessions.refresh_bucket("AAAAA", 1, {999, "forced"})

      assert {:ok, ^generations} = Sessions.generations("AAAAA")
    after
      ClickHouseRepo.query!(
        "RENAME TABLE temporarily_unavailable_years TO analytics_session_years"
      )
    end

    assert {:ok, 0} = Sessions.refresh_changed(limit: 32)
  end

  test "failed physical invalidation hides pointers and reports an error for retry" do
    pair(1, "AAAAA", "video", 20, 25, 0, 5)
    assert {:ok, _} = Sessions.refresh_changed(limit: 32)
    ClickHouseRepo.query!("RENAME TABLE analytics_session_years TO temporarily_unavailable_years")

    try do
      assert {:error, :analytics_unavailable} = Sessions.invalidate("AAAAA")
      assert {:error, :preparing} = Sessions.generations("AAAAA")
    after
      ClickHouseRepo.query!(
        "RENAME TABLE temporarily_unavailable_years TO analytics_session_years"
      )
    end
  end

  test "source deletion invalidates the inventory and cannot retain old totals" do
    pair(1, "AAAAA", "video", 20, 25, 0, 5)
    assert {:ok, _} = Sessions.refresh_changed(limit: 32)

    ClickHouseRepo.query!(
      "ALTER TABLE events DELETE WHERE space_hash = 'AAAAA' SETTINGS mutations_sync = 1"
    )

    assert {:ok, 1} = Sessions.refresh_changed(limit: 32)
    assert {:ok, data} = Sessions.data("AAAAA")
    assert data.views.year == 0
  end

  test "invalid hashes and the shared storage space never expose other tenants" do
    assert {:error, :invalid_space_hash} = Sessions.data("AAAAA' OR 1=1")
    assert {:ok, empty} = Sessions.data("trial")
    assert empty.views.year == 0
    assert Repo.query!("SELECT count(*) FROM analytics_session_buckets").rows == [[0]]
    from = DateTime.add(DateTime.utc_now(), -86_400)
    assert {:ok, %{}} = Sessions.range_data("trial", from, DateTime.utc_now())
  end

  test "range views remain unique across midnight and support video export batches" do
    midnight = DateTime.new!(Date.utc_today(), ~T[00:00:00])
    Process.put(:analytics_time, DateTime.add(midnight, 120))
    pair(1, "AAAAA", "video", 118, 122, 0, 4)
    assert {:ok, _} = Sessions.refresh_changed(limit: 32)
    from = DateTime.add(midnight, -86_400)
    to = DateTime.add(midnight, 86_400)
    assert {:ok, report} = Sessions.range_data("AAAAA", from, to)
    assert report[""].views == 1
    assert report[""].watch_seconds == 4.0
    assert report[Date.to_iso8601(Date.utc_today())].views == 1
    assert report[Date.to_iso8601(Date.add(Date.utc_today(), -1))].views == 1

    assert {:ok, videos} =
             Sessions.range_data("AAAAA", from, to, mode: :videos, embed_hashes: ["video"])

    assert videos["video"].views == 1

    assert {:ok, %{}} =
             Sessions.range_data("AAAAA", from, to, mode: :videos, embed_hashes: ["absent"])
  end

  test "range view thresholds combine a shared session but stay separate per video" do
    pair(1, "AAAAA", "first", 20.4, 21, 0, 0.6)
    pair(1, "AAAAA", "second", 10.4, 11, 0, 0.6)
    assert {:ok, _} = Sessions.refresh_changed(limit: 32)
    to = Process.get(:analytics_time)
    from = DateTime.add(to, -30)
    assert {:ok, report} = Sessions.range_data("AAAAA", from, to)
    assert report[""].views == 1
    assert report[""].watch_seconds == 1.2
    assert {:ok, videos} = Sessions.range_data("AAAAA", from, to, mode: :videos)
    assert videos["first"].views == 0
    assert videos["second"].views == 0
  end

  test "same-count source mutations are detected by the inventory fingerprint" do
    pair(1, "AAAAA", "video", 20, 25, 0, 5)
    assert {:ok, _} = Sessions.refresh_changed(limit: 32)

    ClickHouseRepo.query!("""
    ALTER TABLE events UPDATE device = 'mobile'
    WHERE space_hash = 'AAAAA' SETTINGS mutations_sync = 1
    """)

    assert {:ok, 1} = Sessions.refresh_changed(limit: 32)
    assert {:ok, data} = Sessions.data("AAAAA")
    assert data.watch_time.year == 5000
    assert data.devices == [%{device: "mobile", views: 1}]
  end

  test "empty periods keep the zero series total and no video rows" do
    pair(1, "AAAAA", "first", 20, 25, 0, 5)
    assert {:ok, _} = Sessions.refresh_changed(limit: 32)
    from = DateTime.add(DateTime.utc_now(), 3600)
    to = DateTime.add(from, 3600)

    assert {:ok, %{"" => %{views: 0, watch_seconds: zero, completion_rate: nil}}} =
             Sessions.range_data("AAAAA", from, to)

    assert zero == 0.0
    assert {:ok, %{}} = Sessions.range_data("AAAAA", from, to, mode: :videos)
  end

  test "coarse ranges preserve daily completion semantics across boundaries" do
    id = "00000000-0000-0000-0000-000000000001"

    for {at, name, position} <- [
          {~U[2026-01-30 12:00:00Z], "play", 90},
          {~U[2026-02-02 12:00:00Z], "pause", 0}
        ] do
      ClickHouseRepo.query!(
        "INSERT INTO events (timestamp,name,session_id,space_hash,embed_hash,video_time,duration) VALUES ({$0:DateTime64(6)},{$1:String},{$2:UUID},'AAAAA','long',{$3:Float32},100)",
        [at, name, id, position]
      )
    end

    assert {:ok, _} = Sessions.refresh_changed(limit: 32)
    from = ~U[2026-01-30 12:00:00Z]
    to = ~U[2026-02-02 12:00:00Z]
    assert {:ok, months} = Sessions.range_data("AAAAA", from, to, granularity: :month)
    assert months[""].watch_seconds == 259_200.0
    assert months["2026-01-01"].watch_seconds == 129_600.0
    assert months["2026-02-01"].watch_seconds == 129_600.0
    assert_in_delta months["2026-01-01"].completion_rate, 0.75, 0.00001
    assert_in_delta months["2026-02-01"].completion_rate, 0.15, 0.00001
    assert {:ok, weeks} = Sessions.range_data("AAAAA", from, to, granularity: :week)
    assert weeks["2026-01-26"].watch_seconds == 216_000.0
    assert weeks["2026-02-02"].watch_seconds == 43_200.0
    assert_in_delta weeks["2026-01-26"].completion_rate, 0.75, 0.00001
    assert weeks["2026-02-02"].completion_rate == 0.0
    assert {:ok, videos} = Sessions.range_data("AAAAA", from, to, mode: :videos)
    assert videos["long"].watch_seconds == 259_200.0
    assert videos["long"].completion_rate == 0.0

    assert {:ok, ^months} =
             Sessions.range_data("AAAAA", ~U[2026-01-30 00:00:00Z], ~U[2026-02-03 00:00:00Z],
               granularity: :month
             )

    assert {:ok, ^weeks} =
             Sessions.range_data("AAAAA", ~U[2026-01-30 00:00:00Z], ~U[2026-02-03 00:00:00Z],
               granularity: :week
             )
  end

  test "unique intervals deduplicate within a day while retaining earliest-day attribution" do
    for ago <- [20, 86_420, 172_820], embed <- ["first", "second"] do
      pair(1, "AAAAA", embed, ago, ago + 5, 0, 5)
    end

    assert {:ok, expected} = Analytics.space_data("AAAAA")
    assert {:ok, _} = Sessions.refresh_changed(limit: 32)
    assert {:ok, actual} = Sessions.data("AAAAA", include_unique: true)
    assert actual == expected
    assert actual.unique_watch_time.year == 5000

    assert [[3]] =
             ClickHouseRepo.query!(
               "SELECT sum(length(unique_intervals)) FROM analytics_session_years"
             ).rows
  end

  test "older summaries gain unique intervals without rebuilding raw session rows" do
    pair(1, "AAAAA", "first", 20, 25, 0, 5)
    assert {:ok, _} = Sessions.refresh_changed(limit: 32)

    before =
      ClickHouseRepo.query!("SELECT events,segments,created_at FROM analytics_sessions").rows

    ClickHouseRepo.query!(
      "ALTER TABLE analytics_session_years UPDATE unique_intervals=[] WHERE 1 SETTINGS mutations_sync=1"
    )

    Repo.query!("UPDATE analytics_session_buckets SET format_version=4")
    assert {:ok, 16} = Sessions.refresh_changed(limit: 32)
    {:ok, active} = Sessions.generations("AAAAA")

    assert before ==
             ClickHouseRepo.query!(
               "SELECT events,segments,created_at FROM analytics_sessions WHERE generation IN {$0:Array(UUID)}",
               [active]
             ).rows

    assert {:ok, %{unique_watch_time: %{year: 5000}}} =
             Sessions.data("AAAAA", include_unique: true)
  end

  test "historical reads retain precise unique-watch cutoffs within a day" do
    pair(1, "AAAAA", "first", 20, 25, 0, 5)
    pair(1, "AAAAA", "second", 5, 10, 5, 10)
    assert {:ok, _} = Sessions.refresh_changed(limit: 32)

    assert {:ok, %{unique_watch_time: %{year: 5000}}} =
             Sessions.data("AAAAA",
               include_unique: true,
               now: DateTime.add(Process.get(:analytics_time), -15)
             )

    assert {:ok, %{unique_watch_time: %{year: 10_000}}} =
             Sessions.data("AAAAA", include_unique: true)
  end

  test "overview combines same-day contributions without changing session thresholds" do
    pair(1, "AAAAA", "first", 20, 20.6, 0, 0.6)
    pair(1, "AAAAA", "second", 10, 10.6, 0, 0.6)
    assert {:ok, expected} = Analytics.space_data("AAAAA")
    assert {:ok, _} = Sessions.refresh_changed(limit: 32)
    assert {:ok, actual} = Sessions.data("AAAAA", include_unique: true)
    assert actual == expected
    assert actual.views.today == 1

    assert [[1, 1200]] =
             ClickHouseRepo.query!(
               "SELECT length(days), arraySum(arrayMap(d -> d.2, days)) FROM analytics_session_years"
             ).rows
  end

  test "copied older overview rows combine repeated day entries" do
    pair(1, "AAAAA", "first", 20, 25, 0, 5)
    assert {:ok, _} = Sessions.refresh_changed(limit: 32)

    ClickHouseRepo.query!("""
    ALTER TABLE analytics_session_years UPDATE
      days=[(toDate(first_at),toInt64(2000)),(toDate(first_at),toInt64(3000))]
    WHERE space_hash='AAAAA' SETTINGS mutations_sync=1
    """)

    assert {:ok, before} = Sessions.data("AAAAA")
    Repo.query!("UPDATE analytics_session_buckets SET format_version=3")
    assert {:ok, 16} = Sessions.refresh_changed(limit: 32)
    assert {:ok, after_copy} = Sessions.data("AAAAA")
    assert after_copy == before
    {:ok, active} = Sessions.generations("AAAAA")

    assert [[1, 5000]] =
             ClickHouseRepo.query!(
               "SELECT length(days), arraySum(arrayMap(d -> d.2, days)) FROM analytics_session_years WHERE generation IN {$0:Array(UUID)}",
               [active]
             ).rows
  end

  test "existing session snapshots gain compact reports during a format upgrade" do
    pair(1, "AAAAA", "first", 20, 25, 0, 5)
    assert {:ok, _} = Sessions.refresh_changed(limit: 32)
    Repo.query!("UPDATE analytics_session_buckets SET format_version=3")
    ClickHouseRepo.query!("TRUNCATE TABLE analytics_session_reports")
    assert {:ok, 16} = Sessions.refresh_changed(limit: 32)
    assert {:ok, %{views: %{year: 1}, watch_time: %{year: 5000}}} = Sessions.data("AAAAA")
    assert [[1]] = ClickHouseRepo.query!("SELECT count() FROM analytics_session_reports").rows
  end

  test "very long segments retain exact range fallback without unbounded report expansion" do
    for {at, name, position} <- [
          {~U[2023-01-01 00:00:00Z], "play", 0},
          {~U[2026-01-01 00:00:00Z], "pause", 1}
        ] do
      ClickHouseRepo.query!(
        "INSERT INTO events (timestamp,name,session_id,space_hash,embed_hash,video_time,duration) VALUES ({$0:DateTime64(6)},{$1:String},toUUID('00000000-0000-0000-0000-000000000001'),'AAAAA','long',{$2:Float32},10)",
        [at, name, position]
      )
    end

    assert {:ok, _} = Sessions.refresh_changed(limit: 32)
    assert [[0]] = ClickHouseRepo.query!("SELECT complete FROM analytics_session_reports").rows

    assert {:ok, report} =
             Sessions.range_data("AAAAA", ~U[2025-01-01 00:00:00Z], ~U[2025-01-08 00:00:00Z])

    assert report[""].views == 1
    assert report[""].watch_seconds == 604_800.0
  end

  test "partial future days use clipped segments instead of complete day reports" do
    target = DateTime.new!(Date.add(Date.utc_today(), 2), ~T[12:00:00])
    Process.put(:analytics_time, target)
    pair(1, "AAAAA", "future", -5, 5, 0, 10)
    assert {:ok, _} = Sessions.refresh_changed(limit: 32)
    from = DateTime.new!(DateTime.to_date(target), ~T[00:00:00])
    assert {:ok, report} = Sessions.range_data("AAAAA", from, target)
    assert report[""].watch_seconds == 5.0
  end

  test "future-dated pauses become visible without another insert" do
    pair(1, "AAAAA", "normal", 20, 25, 0, 5)
    # Keep another ordinary session in the same bucket so an empty future
    # array cannot mask this session's scheduled refresh deadline.
    Process.put(:analytics_time, DateTime.utc_now())
    pair(1, "AAAAA", "future", -15, -10, 0, 5)
    assert {:ok, _} = Sessions.refresh_changed(limit: 32)
    assert {:ok, before} = Sessions.data("AAAAA")
    assert before.watch_time.year == 5000
    Process.sleep(16_000)
    assert {:ok, 1} = Sessions.refresh_changed(limit: 32)
    assert {:ok, later} = Sessions.data("AAAAA")
    assert later.watch_time.year == 10_000
  end

  test "cleanup retains published generations and removes only expired ones" do
    pair(1, "AAAAA", "first", 20, 25, 0, 5)
    assert {:ok, _} = Sessions.refresh_changed(limit: 32)

    ClickHouseRepo.query!(
      "ALTER TABLE analytics_sessions UPDATE created_at = now() - INTERVAL 2 HOUR WHERE 1 SETTINGS mutations_sync = 1"
    )

    ClickHouseRepo.query!(
      "ALTER TABLE analytics_session_years UPDATE created_at = now() - INTERVAL 2 HOUR WHERE 1 SETTINGS mutations_sync = 1"
    )

    pair(1, "AAAAA", "second", 10, 15, 0, 5)
    assert {:ok, 1} = Sessions.refresh_changed(limit: 32)
    # The old snapshot was just retired, even though it was built two hours ago.
    assert :ok = Sessions.cleanup()
    assert ClickHouseRepo.query!("SELECT count() FROM analytics_sessions").rows == [[2]]

    Repo.query!(
      "UPDATE analytics_session_retirements SET retired_at = now() - interval '2 hours'"
    )

    assert :ok = Sessions.cleanup()
    assert ClickHouseRepo.query!("SELECT count() FROM analytics_sessions").rows == [[1]]
    assert ClickHouseRepo.query!("SELECT count() FROM analytics_session_years").rows == [[1]]
    assert {:ok, data} = Sessions.data("AAAAA")
    assert data.watch_time.year == 10_000
  end

  test "cleanup makes bounded progress through a retirement backlog" do
    pair(1, "AAAAA", "first", 20, 25, 0, 5)
    assert {:ok, _} = Sessions.refresh_changed(limit: 32)
    pair(1, "AAAAA", "second", 10, 15, 0, 5)
    assert {:ok, 1} = Sessions.refresh_changed(limit: 32)
    pair(1, "AAAAA", "third", 5, 10, 0, 5)
    assert {:ok, 1} = Sessions.refresh_changed(limit: 32)
    Repo.query!("UPDATE analytics_session_retirements SET retired_at=now()-interval '2 hours'")
    Application.put_env(:mave_core, :analytics_sessions, cleanup_generation_limit: 1)
    assert :ok = Sessions.cleanup()
    assert [[2]] = ClickHouseRepo.query!("SELECT count() FROM analytics_sessions").rows
    assert :ok = Sessions.cleanup()
    assert [[1]] = ClickHouseRepo.query!("SELECT count() FROM analytics_sessions").rows
    assert {:ok, %{views: %{year: 1}}} = Sessions.data("AAAAA")
  end

  test "cleanup discovers an unpublished generation and preserves active readers" do
    pair(1, "AAAAA", "first", 20, 25, 0, 5)
    assert {:ok, _} = Sessions.refresh_changed(limit: 32)
    {:ok, active} = Sessions.generations("AAAAA")
    # Simulate a crash after the ClickHouse insert but before first publication.
    ClickHouseRepo.query!(
      "INSERT INTO analytics_sessions SELECT * REPLACE('CCCCC' AS space_hash) FROM analytics_sessions"
    )

    assert :ok = Sessions.cleanup()

    assert [[1]] =
             Repo.query!(
               "SELECT count(*) FROM analytics_session_retirements WHERE space_hash='CCCCC'"
             ).rows

    Repo.query!("UPDATE analytics_session_retirements SET retired_at=now()-interval '2 hours'")
    # A stale retirement record must never delete a currently published version.
    Repo.query!(
      "INSERT INTO analytics_session_retirements SELECT space_hash,generation,now()-interval '2 hours' FROM analytics_session_buckets ON CONFLICT DO NOTHING"
    )

    assert :ok = Sessions.cleanup()

    assert [[0]] =
             ClickHouseRepo.query!(
               "SELECT count() FROM analytics_sessions WHERE space_hash='CCCCC'"
             ).rows

    assert {:ok, ^active} = Sessions.generations("AAAAA")
    assert {:ok, %{views: %{year: 1}}} = Sessions.data("AAAAA")
  end

  defp pair(id, space, embed, pause_ago, play_ago, start, finish) do
    event(id, space, embed, "play", play_ago, start)
    event(id, space, embed, "pause", pause_ago, finish)
  end

  defp event(id, space, embed, name, seconds_ago, position) do
    uuid = "00000000-0000-0000-0000-" <> String.pad_leading(to_string(id), 12, "0")

    ClickHouseRepo.query!(
      """
      INSERT INTO events (timestamp, name, session_id, space_hash, embed_hash,
        video_time, duration, device, browser, os, source_url)
      VALUES ({$0:DateTime64(6)}, {$1:String}, {$2:UUID},
        {$3:String}, {$4:String}, {$5:Float32}, 60, 'desktop', 'Chrome', 'Linux', 'https://example.test')
      """,
      [
        DateTime.add(Process.get(:analytics_time), -round(seconds_ago * 1000), :millisecond),
        name,
        uuid,
        space,
        embed,
        position
      ]
    )
  end
end
