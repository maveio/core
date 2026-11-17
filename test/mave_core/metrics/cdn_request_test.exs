defmodule MaveCore.Metrics.CdnRequestTest do
  use ExUnit.Case, async: true

  alias MaveCore.Metrics.CdnRequest

  @now_ms 1_794_863_000_000

  defp record(overrides \\ %{}) do
    Map.merge(
      %{
        "timestamp" => @now_ms - 5_000,
        "url" =>
          "https://space-ab1cd.cdn.example/VIDEOHASH0/h264/720p/segment_4.m4s?token=secret",
        "status" => 200,
        "cache_status" => "HIT",
        "bytes" => 734_112,
        "ttfb_ms" => 23.4,
        "country" => "nl",
        "pop" => "AMS"
      },
      overrides
    )
  end

  test "normalizes a reported request" do
    assert {:ok,
            %{
              timestamp: ~U[2026-11-16 21:03:15.000000Z],
              space_hash: "ab1cd",
              embed_hash: "VIDEOHASH0",
              status: 200,
              cache_status: "hit",
              origin: 0,
              bytes: 734_112,
              ttfb_ms: 23,
              country: "NL",
              pop: "AMS"
            }} = CdnRequest.normalize(record(), @now_ms)
  end

  test "finds the video in every media URL layout" do
    assert {:ok, "ab1cd", "VIDEOHASH0"} =
             CdnRequest.attribute("space-ab1cd.media.example", "/VIDEOHASH0/manifest.json")

    assert {:ok, "ab1cd", "VIDEOHASH0"} =
             CdnRequest.attribute("cdn.example", "/space-ab1cd/VIDEOHASH0/h264/1080p/video.m3u8")

    assert {:ok, "ab1cd", "VIDEOHASH0"} =
             CdnRequest.attribute(
               "api.example",
               "/api/v1/playback/media/ab1cdVIDEOHASH0/poster.jpg"
             )

    assert :error = CdnRequest.attribute("cdn.example", "/assets/app.js")
    assert :error = CdnRequest.attribute("space-ab1cd.media.example", "/short/manifest.json")
    assert :error = CdnRequest.attribute(nil, nil)
  end

  test "accepts an embed id, or a host and path, instead of a URL" do
    assert {:ok, %{space_hash: "ab1cd", embed_hash: "VIDEOHASH0"}} =
             record(%{"embed_id" => "ab1cdVIDEOHASH0"})
             |> Map.delete("url")
             |> CdnRequest.normalize(@now_ms)

    assert {:ok, %{space_hash: "ab1cd", embed_hash: "VIDEOHASH0"}} =
             record(%{"host" => "cdn.example", "path" => "/space-ab1cd/VIDEOHASH0/a.m4s?x=1"})
             |> Map.delete("url")
             |> CdnRequest.normalize(@now_ms)
  end

  test "maps provider cache statuses and derives origin requests" do
    for {status, expected, origin} <- [
          {"HIT", "hit", 0},
          {"STALE", "hit", 0},
          {"REVALIDATED", "hit", 0},
          {"MISS", "miss", 1},
          {"EXPIRED", "miss", 1},
          {"BYPASS", "bypass", 1},
          {"DYNAMIC", "bypass", 1},
          {"something-new", "unknown", 1},
          {nil, "unknown", 1}
        ] do
      assert {:ok, %{cache_status: ^expected, origin: ^origin}} =
               CdnRequest.normalize(record(%{"cache_status" => status}), @now_ms)
    end

    assert {:ok, %{cache_status: "hit", origin: 1}} =
             CdnRequest.normalize(record(%{"origin" => true}), @now_ms)
  end

  test "accepts ISO 8601 timestamps and bounds measurements" do
    assert {:ok, %{timestamp: ~U[2026-11-16 21:00:00.000000Z], ttfb_ms: 600_000, bytes: 0}} =
             CdnRequest.normalize(
               record(%{
                 "timestamp" => "2026-11-16T22:00:00+01:00",
                 "ttfb_ms" => 9_999_999,
                 "bytes" => -5
               }),
               @now_ms
             )
  end

  test "drops records that cannot be attributed or trusted" do
    for overrides <- [
          %{"url" => "https://cdn.example/assets/app.js"},
          %{"status" => 999},
          %{"status" => "ok"},
          %{"timestamp" => @now_ms - 40 * 86_400_000},
          %{"timestamp" => @now_ms + 3_600_000},
          %{"timestamp" => "yesterday"},
          %{"timestamp" => nil}
        ] do
      assert :error = CdnRequest.normalize(record(overrides), @now_ms)
    end

    assert :error = CdnRequest.normalize("not a record", @now_ms)
  end
end
