defmodule MaveCore.Analytics.PerformanceTest do
  use MaveCore.DataCase, async: false

  alias MaveCore.Analytics.Performance
  alias MaveCore.ClickHouseRepo
  alias MaveCore.Metrics.CdnRequest
  alias MaveCore.Metrics.PlaybackQuality

  @now ~U[2026-10-14 15:30:00Z]
  @space "perfa"

  setup do
    db_name = ClickHouseRepo.config()[:database] || "mave_metrics"
    ClickHouseRepo.query("TRUNCATE TABLE IF EXISTS #{db_name}.playback_quality")
    ClickHouseRepo.query("TRUNCATE TABLE IF EXISTS #{db_name}.cdn_requests")
    {:ok, db_name: db_name}
  end

  test "combines what viewers experienced with what delivery did", %{db_name: db_name} do
    at = ~U[2026-10-13 10:00:00.000000Z]

    # A healthy attempt: starts in 800 ms, plays a minute at 1080p.
    attempt(db_name, 1, "VIDEOAAAAA", at, [
      {"playback_request", %{}},
      {"playback_startup", %{startup_ms: 800}},
      {"playback_sample", %{playing_ms: 60_000, bitrate: 4_000_000, width: 1920, height: 1080}}
    ])

    # A struggling attempt: slow start, a stall, lower rendition, then an error.
    attempt(db_name, 2, "VIDEOAAAAA", at, [
      {"playback_request", %{}},
      {"playback_startup", %{startup_ms: 3_200}},
      {"playback_sample", %{playing_ms: 20_000, bitrate: 1_000_000, width: 1280, height: 720}},
      {"playback_rebuffer", %{rebuffer_ms: 5_000}},
      {"playback_error", %{error_code: "MEDIA_ERR_NETWORK"}}
    ])

    # Never started.
    attempt(db_name, 3, "VIDEOBBBBB", at, [
      {"playback_request", %{}},
      {"playback_error", %{error_code: "MEDIA_ERR_SRC_NOT_SUPPORTED"}}
    ])

    # Outside the selected week.
    attempt(db_name, 4, "VIDEOAAAAA", ~U[2026-10-01 10:00:00.000000Z], [
      {"playback_startup", %{startup_ms: 60_000}}
    ])

    requests(db_name, "VIDEOAAAAA", at, [
      {200, "hit", 1_000, 20},
      {200, "hit", 1_000, 30},
      {200, "miss", 2_000, 400},
      {503, "miss", 0, 900}
    ])

    assert {:ok, report} = Performance.report(@space, "week", @now)

    assert %{
             attempts: 3,
             startups: 2,
             startup_p50_ms: 2_000,
             startup_failures: 1,
             playback_failures: 1,
             rebuffers: 1,
             rebuffered_attempts: 1,
             playing_ms: 80_000,
             rebuffer_ms: 5_000,
             avg_bitrate: 3_250_000
           } = report.experience

    assert_in_delta report.experience.failure_rate, 2 / 3, 0.001
    assert_in_delta report.experience.rebuffer_ratio, 5 / 85, 0.001

    assert %{
             requests: 4,
             hits: 2,
             misses: 2,
             cache_hit_ratio: 0.5,
             origin_requests: 2,
             bytes: 4_000,
             origin_bytes: 2_000,
             server_errors: 1,
             error_rate: 0.25
           } = report.delivery

    assert report.bucket == :day
    assert length(report.series) == 7

    assert %{experience: %{attempts: 3}, delivery: %{requests: 4}} =
             Enum.find(report.series, &(&1.start == ~U[2026-10-13 00:00:00Z]))

    assert %{experience: nil, delivery: nil} = hd(report.series)

    assert [%{height: 1080, share: 0.75}, %{height: 720, share: 0.25}] = report.resolutions

    assert [
             %{key: "VIDEOAAAAA", experience: %{attempts: 2}, delivery: %{requests: 4}},
             %{key: "VIDEOBBBBB", experience: %{attempts: 1}, delivery: nil}
           ] = report.breakdowns.video

    assert [%{key: "NL", experience: %{attempts: 3}, delivery: %{requests: 4}}] =
             report.breakdowns.region

    assert [%{key: "desktop", delivery: nil}] = report.breakdowns.device
    assert [%{key: "Chrome", delivery: nil}] = report.breakdowns.browser
  end

  test "returns an empty report for a space without measurements" do
    assert {:ok, %{experience: %{attempts: 0, startup_p50_ms: nil, failure_rate: nil}} = report} =
             Performance.report(@space, "today", @now)

    assert report.delivery == nil
    assert report.findings == []
    assert report.breakdowns.video == []
    assert Performance.empty("today", @now) == report
  end

  test "rejects unknown periods and malformed space hashes" do
    assert {:error, :invalid_request} = Performance.report(@space, "decade", @now)
    assert {:error, :invalid_request} = Performance.report("x'; --", "week", @now)
  end

  describe "findings/1" do
    test "attributes a slow region to cache misses" do
      report =
        report_with(
          region: [
            segment("DE", %{attempts: 40, startup_p50_ms: 2_600}, %{cache_hit_ratio: 0.55}),
            segment("NL", %{attempts: 160}, %{})
          ]
        )

      assert [
               %{
                 dimension: :region,
                 key: "DE",
                 symptoms: [%{metric: :startup, value: 2_600, baseline: 900}],
                 causes: [%{type: :cache_misses, value: 0.55, baseline: 0.95}]
               }
             ] = Performance.findings(report)
    end

    test "points at the viewer's side when delivery is healthy" do
      report =
        report_with(
          video: [segment("VIDEOAAAAA", %{attempts: 30, failure_rate: 0.2}, %{})],
          browser: [segment("Safari", %{attempts: 50, rebuffer_ratio: 0.08}, nil)]
        )

      assert [
               %{dimension: :browser, causes: [%{type: :client}]},
               %{dimension: :video, causes: [%{type: :delivery_healthy}]}
             ] = Performance.findings(report)
    end

    test "ignores small segments and segments in line with the space" do
      report =
        report_with(
          region: [
            segment("SE", %{attempts: 5, startup_p50_ms: 9_000}, %{}),
            segment("NL", %{attempts: 150, startup_p50_ms: 1_000}, %{})
          ]
        )

      assert Performance.findings(report) == []
    end

    test "needs enough affected plays before a rate counts" do
      unlucky = %{attempts: 40, failure_rate: 0.1, startup_failures: 2, playback_failures: 2}
      report = report_with(browser: [segment("Opera", unlucky, nil)])

      assert Performance.findings(report) == []
    end
  end

  defp report_with(breakdowns) do
    %{
      experience: experience(%{attempts: 200}),
      delivery: delivery(%{}),
      breakdowns:
        Map.merge(%{video: [], device: [], browser: [], region: []}, Map.new(breakdowns))
    }
  end

  defp segment(key, experience, delivery) do
    %{key: key, experience: experience(experience), delivery: delivery && delivery(delivery)}
  end

  defp experience(overrides) do
    Map.merge(
      %{
        attempts: 100,
        startups: 100,
        startup_p50_ms: 900,
        rebuffered_attempts: 20,
        rebuffer_ratio: 0.01,
        startup_failures: 10,
        playback_failures: 10,
        failure_rate: 0.01
      },
      overrides
    )
  end

  defp delivery(overrides) do
    Map.merge(
      %{requests: 1_000, cache_hit_ratio: 0.95, ttfb_p95_ms: 120, error_rate: 0.002},
      overrides
    )
  end

  defp attempt(db_name, number, embed_hash, at, events) do
    rows =
      events
      |> Enum.with_index()
      |> Enum.map(fn {{name, measurements}, index} ->
        Map.merge(
          %{
            timestamp: DateTime.add(at, index, :second),
            name: name,
            session_id: "00000000-0000-4000-8000-#{String.pad_leading("#{number}", 12, "0")}",
            space_hash: @space,
            embed_hash: embed_hash,
            startup_ms: 0,
            rebuffer_ms: 0,
            playing_ms: 0,
            bitrate: 0,
            width: 0,
            height: 0,
            error_code: "",
            browser: "Chrome",
            os: "Mac",
            device: "desktop",
            country: "NL"
          },
          measurements
        )
      end)

    ClickHouseRepo.insert_all(PlaybackQuality, rows, prefix: db_name)
  end

  defp requests(db_name, embed_hash, at, requests) do
    rows =
      Enum.map(requests, fn {status, cache_status, bytes, ttfb_ms} ->
        %{
          timestamp: at,
          space_hash: @space,
          embed_hash: embed_hash,
          status: status,
          cache_status: cache_status,
          origin: if(cache_status == "hit", do: 0, else: 1),
          bytes: bytes,
          ttfb_ms: ttfb_ms,
          country: "NL",
          pop: "AMS"
        }
      end)

    ClickHouseRepo.insert_all(CdnRequest, rows, prefix: db_name)
  end
end
