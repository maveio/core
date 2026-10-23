defmodule MaveCore.Analytics.RangeReportTest do
  use ExUnit.Case, async: false

  alias MaveCore.Analytics.Range
  alias MaveCore.Analytics.RangeReport
  alias MaveCore.ClickHouseRepo

  setup do
    {:ok, _} = ClickHouseRepo.query("TRUNCATE TABLE events")
    :ok
  end

  test "clips segments at both UTC boundaries and keeps existing one-second view threshold" do
    pair("abcde", "AAAAAAAAAA", 1, "2024-02-28 23:59:58", "2024-02-29 00:00:02", 0, 4, 10)
    pair("abcde", "AAAAAAAAAA", 2, "2024-02-29 23:59:58", "2024-03-01 00:00:03", 0, 5, 10)
    pair("abcde", "AAAAAAAAAA", 3, "2024-02-29 10:00:00", "2024-02-29 10:00:00.5", 0, 0.5, 10)
    pair("other", "AAAAAAAAAA", 4, "2024-02-29 10:00:00", "2024-02-29 10:01:00", 0, 60, 60)
    pair("abcde", "BBBBBBBBBB", 5, "2024-03-01 00:00:00", "2024-03-01 00:00:05", 0, 5, 10)

    range = %Range{from: ~D[2024-02-29], to: ~D[2024-02-29]}
    assert {:ok, report} = RangeReport.fetch("abcde", range)
    assert report.totals.views == 2
    assert_in_delta report.totals.watch_seconds, 4.5, 0.0001
    assert_in_delta report.totals.completion_rate, 0.3, 0.0001
    assert [%{date: ~D[2024-02-29], views: 2, watch_seconds: 4.5}] = report.series

    assert {:ok, metrics} = RangeReport.videos("abcde", range, ["AAAAAAAAAA"])
    assert metrics["AAAAAAAAAA"] == report.totals
  end

  test "deduplicates total sessions, splits cross-midnight time, and fills empty buckets" do
    pair("abcde", "AAAAAAAAAA", 1, "2024-02-28 23:59:58", "2024-02-29 00:00:02", 0, 4, 10)
    range = %Range{from: ~D[2024-02-28], to: ~D[2024-03-01]}
    assert {:ok, report} = RangeReport.fetch("abcde", range)
    assert report.totals.views == 1
    assert report.totals.watch_seconds == 4.0
    assert Enum.map(report.series, & &1.views) == [1, 1, 0]
    assert Enum.map(report.series, & &1.watch_seconds) == [2.0, 2.0, 0.0]

    for granularity <- ~w(week month) do
      assert {:ok, grouped} = RangeReport.fetch("abcde", %{range | granularity: granularity})
      assert grouped.totals == report.totals
      assert Enum.sum(Enum.map(grouped.series, & &1.watch_seconds)) == 4.0
    end
  end

  test "unknown durations are excluded and completion is capped at one" do
    pair("abcde", "AAAAAAAAAA", 1, "2024-02-29 00:00:00", "2024-02-29 00:00:05", 0, 50, 10)
    pair("abcde", "AAAAAAAAAA", 2, "2024-02-29 00:01:00", "2024-02-29 00:01:05", 0, 5, 0)
    range = %Range{from: ~D[2024-02-29], to: ~D[2024-02-29]}
    assert {:ok, report} = RangeReport.fetch("abcde", range)
    assert report.totals == %{views: 2, watch_seconds: 10.0, completion_rate: 1.0}
    assert {:ok, empty} = RangeReport.fetch("abcde", range, "BBBBBBBBBB")
    assert empty.totals == %{views: 0, watch_seconds: 0.0, completion_rate: nil}
  end

  test "shared storage trial spaces do not expose merged metrics" do
    pair("trial", "AAAAAAAAAA", 1, "2024-02-29 00:00:00", "2024-02-29 00:00:05", 0, 5, 10)

    assert {:ok, report} =
             RangeReport.fetch("trial", %Range{from: ~D[2024-02-29], to: ~D[2024-02-29]})

    assert report.totals.views == 0
  end

  defp pair(space, embed, id, from, to, start_time, end_time, duration) do
    session = "00000000-0000-0000-0000-" <> String.pad_leading(to_string(id), 12, "0")

    for {time, name, position} <- [{from, "play", start_time}, {to, "pause", end_time}] do
      {:ok, _} =
        ClickHouseRepo.query(
          """
          INSERT INTO events (timestamp, name, session_id, space_hash, embed_hash, video_time, duration)
          VALUES (parseDateTime64BestEffort({$0:String}, 6, 'UTC'), {$1:String}, {$2:UUID}, {$3:String}, {$4:String}, {$5:Float64}, {$6:Float64})
          """,
          [time, name, session, space, embed, position, duration]
        )
    end
  end
end
