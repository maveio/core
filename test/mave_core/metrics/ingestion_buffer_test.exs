defmodule MaveCore.Metrics.IngestionBufferTest do
  use ExUnit.Case, async: false

  alias MaveCore.ClickHouseRepo
  alias MaveCore.Metrics.CdnRequest
  alias MaveCore.Metrics.IngestionBuffer

  @session_id "12470000-0000-4000-8000-000000000001"
  @user_agent "Mozilla/5.0 (iPhone; CPU iPhone OS 17_0 like Mac OS X) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/17.0 Mobile/15E148 Safari/604.1"

  setup do
    db_name = ClickHouseRepo.config()[:database] || "mave_metrics"

    for table <- ~w(events playback_quality cdn_requests),
        do: ClickHouseRepo.query!("TRUNCATE TABLE IF EXISTS #{db_name}.#{table}")

    {:ok, db_name: db_name}
  end

  test "stores playback quality events apart from engagement events", %{db_name: db_name} do
    now_ms = System.system_time(:millisecond)

    event = fn name, measurements ->
      Map.merge(
        %{
          "name" => name,
          "session_id" => @session_id,
          "timestamp" => now_ms,
          "embed_id" => "bufqaVIDEOHASH0",
          "user_agent" => @user_agent,
          "country" => "de"
        },
        measurements
      )
    end

    ref =
      Broadway.test_batch(IngestionBuffer, [
        event.("play", %{"video_time" => 0}),
        event.("playback_startup", %{"startup_ms" => 1_240.6}),
        event.("playback_sample", %{
          "playing_ms" => 10_000,
          "bitrate" => 2_500_000,
          "width" => 1280,
          "height" => 720
        }),
        event.("playback_rebuffer", %{"rebuffer_ms" => 99_999_999}),
        event.("playback_error", %{"error_code" => "MEDIA_ERR_NETWORK <script>"})
      ])

    # One acknowledgement per destination table.
    assert_receive {:ack, ^ref, [_ | _], []}, 5_000
    assert_receive {:ack, ^ref, [_ | _], []}, 5_000

    assert %{rows: [["play"]]} =
             ClickHouseRepo.query!(
               "SELECT name FROM #{db_name}.events WHERE space_hash = 'bufqa'"
             )

    assert %{rows: rows} =
             ClickHouseRepo.query!("""
             SELECT name, embed_hash, startup_ms, rebuffer_ms, playing_ms, bitrate, width, height,
               error_code, browser, device, country
             FROM #{db_name}.playback_quality WHERE space_hash = 'bufqa' ORDER BY name
             """)

    assert [
             [
               "playback_error",
               "VIDEOHASH0",
               0,
               0,
               0,
               0,
               0,
               0,
               "MEDIA_ERR_NETWORKscript",
               "Mobile Safari",
               "smartphone",
               "DE"
             ],
             ["playback_rebuffer", _, 0, 600_000, 0, 0, 0, 0, "", _, _, "DE"],
             ["playback_sample", _, 0, 0, 10_000, 2_500_000, 1280, 720, "", _, _, "DE"],
             ["playback_startup", _, 1_240, 0, 0, 0, 0, 0, "", _, _, "DE"]
           ] = rows
  end

  test "stores normalized CDN requests", %{db_name: db_name} do
    {:ok, row} =
      CdnRequest.normalize(%{
        "timestamp" => System.system_time(:millisecond),
        "embed_id" => "bufqaVIDEOHASH0",
        "status" => 503,
        "cache_status" => "MISS",
        "bytes" => 512,
        "ttfb_ms" => 840,
        "country" => "DE",
        "pop" => "FRA"
      })

    ref = Broadway.test_batch(IngestionBuffer, [{:cdn_request, row}])
    assert_receive {:ack, ^ref, [_], []}, 5_000

    assert %{rows: [["VIDEOHASH0", 503, "miss", 1, 512, 840, "DE", "FRA"]]} =
             ClickHouseRepo.query!("""
             SELECT embed_hash, status, cache_status, origin, bytes, ttfb_ms, country, pop
             FROM #{db_name}.cdn_requests WHERE space_hash = 'bufqa'
             """)
  end
end
