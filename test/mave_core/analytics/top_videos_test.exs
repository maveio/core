defmodule MaveCore.Analytics.TopVideosTest do
  use MaveCore.DataCase, async: false

  alias MaveCore.{Analytics, ClickHouseRepo}
  alias MaveCore.Analytics.Sessions

  setup do
    previous = Application.get_env(:mave_core, :analytics_sessions)
    Application.put_env(:mave_core, :analytics_sessions, enabled: true)

    for table <- ~w(events analytics_sessions analytics_session_years analytics_session_reports) do
      ClickHouseRepo.query!("TRUNCATE TABLE #{table}")
    end

    on_exit(fn -> Application.put_env(:mave_core, :analytics_sessions, previous || []) end)
    :ok
  end

  test "whole and partial periods preserve per-session thresholds and video isolation" do
    pair(1, "AAAAA", "alpha", ~U[2026-08-01 12:00:00Z], ~U[2026-08-01 12:00:00.600000Z])
    pair(1, "AAAAA", "alpha", ~U[2026-08-02 12:00:00Z], ~U[2026-08-02 12:00:00.600000Z])
    pair(2, "AAAAA", "beta", ~U[2026-08-01 23:59:59.500000Z], ~U[2026-08-02 00:00:02Z])
    pair(2, "AAAAA", "gamma", ~U[2026-08-02 12:00:00Z], ~U[2026-08-02 12:00:02Z])
    pair(3, "AAAAA", "alpha", ~U[2026-08-03 12:00:00Z], ~U[2026-08-03 12:00:02Z])
    pair(4, "BBBBB", "other", ~U[2026-08-02 12:00:00Z], ~U[2026-08-02 12:00:05Z])
    assert {:ok, 16} = Sessions.refresh_changed(space_hash: "AAAAA", limit: 16)

    for {from, to} <- [
          {~U[2026-08-01 00:00:00Z], ~U[2026-08-04 00:00:00Z]},
          {~U[2026-08-01 00:00:00Z], ~U[2026-08-02 00:00:00Z]},
          {~U[2026-08-02 00:00:00Z], ~U[2026-08-03 00:00:00Z]},
          {~U[2026-08-01 23:59:59.800000Z], ~U[2026-08-03 12:00:01.100000Z]},
          {~U[2026-08-02 00:00:00.500000Z], ~U[2026-08-02 12:00:00.500000Z]},
          {~U[2026-09-01 00:00:00Z], ~U[2026-10-01 00:00:00Z]}
        ] do
      assert_matches_range(from, to)
    end

    assert {:ok, [%{embed_hash: "alpha", views: 2}]} =
             Analytics.space_top_videos(
               "AAAAA",
               ~U[2026-08-01 00:00:00Z],
               ~U[2026-08-04 00:00:00Z],
               1
             )
  end

  test "future and incomplete reports use precise segments" do
    now = DateTime.utc_now() |> DateTime.truncate(:second)
    future = DateTime.add(now, 86_400)
    pair(1, "AAAAA", "future", future, DateTime.add(future, 3))
    pair(2, "AAAAA", "long", ~U[2020-01-01 00:00:00Z], ~U[2025-01-01 00:00:00Z])
    assert {:ok, 16} = Sessions.refresh_changed(space_hash: "AAAAA", limit: 16)

    assert_matches_range(DateTime.add(future, 1), DateTime.add(future, 5))
    assert_matches_range(~U[2024-01-01 00:00:00Z], ~U[2024-01-02 00:00:00Z])
  end

  test "many videos in one session keep deterministic ranking and a bounded result" do
    ClickHouseRepo.query!("""
    INSERT INTO events (timestamp,name,session_id,space_hash,embed_hash,video_time,duration)
    SELECT toDateTime64('2026-08-01 00:00:00',6) + toIntervalSecond(number * 3),
      if(modulo(number,2)=0,'play','pause'),
      toUUID('00000000-0000-0000-0000-000000000001'),'AAAAA',
      concat('video',leftPad(toString(intDiv(number,2)),5,'0')), 0, 10
    FROM numbers(2048)
    """)

    assert {:ok, 16} = Sessions.refresh_changed(space_hash: "AAAAA", limit: 16)

    assert {:ok, rows} =
             Sessions.top_videos("AAAAA", ~U[2026-08-01 00:00:00Z], ~U[2026-08-02 00:00:00Z], 5)

    assert rows ==
             Enum.map(0..4, fn number ->
               %{embed_hash: "video" <> String.pad_leading(to_string(number), 5, "0"), views: 1}
             end)
  end

  test "raw fallback clips crossing segments to the requested period" do
    pair(1, "AAAAA", "crossing", ~U[2026-08-01 23:59:58Z], ~U[2026-08-02 00:00:02Z])
    from = ~U[2026-08-02 00:00:00Z]
    to = ~U[2026-08-03 00:00:00Z]
    assert {:ok, 16} = Sessions.refresh_changed(space_hash: "AAAAA", limit: 16)
    assert {:ok, expected} = Analytics.space_top_videos("AAAAA", from, to)

    Application.put_env(:mave_core, :analytics_sessions, enabled: false)
    assert {:ok, ^expected} = Analytics.space_top_videos("AAAAA", from, to)
  end

  test "validates bounds and limits, and preserves preparing and empty states" do
    from = ~U[2026-08-01 00:00:00Z]
    to = ~U[2026-08-02 00:00:00Z]
    assert {:error, :invalid_range} = Sessions.top_videos("AAAAA", to, from)
    assert {:error, :invalid_range} = Sessions.top_videos("AAAAA", from, to, 251)
    assert {:error, :invalid_space_hash} = Sessions.top_videos("bad", from, to)
    assert {:ok, []} = Sessions.top_videos("AAAAA", from, to)
    assert {:ok, []} = Sessions.top_videos("trial", from, to)
    pair(1, "AAAAA", "pending", from, DateTime.add(from, 2))
    assert {:error, :preparing} = Sessions.top_videos("AAAAA", from, to)
  end

  defp assert_matches_range(from, to) do
    {:ok, videos} = Sessions.range_data("AAAAA", from, to, mode: :videos)

    expected =
      videos
      |> Enum.filter(fn {_hash, metrics} -> metrics.views > 0 end)
      |> Enum.sort_by(fn {hash, metrics} -> {-metrics.views, hash} end)
      |> Enum.map(fn {hash, metrics} -> %{embed_hash: hash, views: metrics.views} end)

    assert {:ok, ^expected} = Analytics.space_top_videos("AAAAA", from, to)
  end

  defp pair(id, space, hash, from, to) do
    session = "00000000-0000-0000-0000-" <> String.pad_leading(to_string(id), 12, "0")

    for {name, at, position} <- [{"play", from, 0.0}, {"pause", to, 3.0}] do
      ClickHouseRepo.query!(
        """
        INSERT INTO events (timestamp,name,session_id,space_hash,embed_hash,video_time,duration)
        VALUES ({$0:DateTime64(6)},{$1:String},{$2:UUID},{$3:String},{$4:String},{$5:Float32},10)
        """,
        [at, name, session, space, hash, position]
      )
    end
  end
end
