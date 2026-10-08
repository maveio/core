defmodule MaveCore.Media.PlaylistTest do
  use ExUnit.Case, async: true
  alias MaveCore.Media.Playlist

  @master_playlist """
  #EXTM3U
  #EXT-X-VERSION:3
  #EXT-X-STREAM-INF:BANDWIDTH=800000,RESOLUTION=640x360
  360p/playlist.m3u8
  #EXT-X-STREAM-INF:BANDWIDTH=1400000,RESOLUTION=842x480
  480p/playlist.m3u8
  #EXT-X-STREAM-INF:BANDWIDTH=2800000,RESOLUTION=1280x720
  720p/playlist.m3u8
  """

  @variant_playlist """
  #EXTM3U
  #EXT-X-VERSION:3
  #EXT-X-TARGETDURATION:6
  #EXT-X-MAP:URI="init.mp4"
  #EXTINF:6.000000,
  segment0.m4s
  #EXTINF:6.000000,
  segment1.m4s
  #EXTINF:4.500000,
  segment2.m4s
  #EXT-X-ENDLIST
  """

  describe "segment_at_time/2" do
    test "finds segment at start" do
      assert {:ok, info} = Playlist.segment_at_time(@variant_playlist, 0.0)
      assert info.segment == "segment0.m4s"
      assert info.start == 0.0
      assert info.init == "init.mp4"
    end

    test "finds segment in middle" do
      # Start 6.0, duration 6.0. Target 8.0 should be in segment1
      assert {:ok, info} = Playlist.segment_at_time(@variant_playlist, 8.0)
      assert info.segment == "segment1.m4s"
    end

    test "returns last segment if time is out of range" do
      # Total 6+6+4.5 = 16.5
      # Target 100
      assert {:ok, info} = Playlist.segment_at_time(@variant_playlist, 100.0)
      assert info.segment == "segment2.m4s"
      assert info.start == 12.0
      assert info.duration == 4.5
    end
  end

  describe "select_variant/2" do
    test "selects highest bandwidth by default" do
      {:ok, uri, resolution} = Playlist.select_variant(@master_playlist)
      assert uri == "720p/playlist.m3u8"
      assert resolution == {1280, 720}
    end

    test "selects variant closest to target width (exact match)" do
      {:ok, uri, resolution} = Playlist.select_variant(@master_playlist, width: 842)
      assert uri == "480p/playlist.m3u8"
      assert resolution == {842, 480}
    end

    test "selects variant closest to target width (closest approximation)" do
      # Target 400 maps closer to 360p (diff 240) than 480p (diff 442) -> 360p
      {:ok, uri, resolution} = Playlist.select_variant(@master_playlist, width: 400)
      assert uri == "360p/playlist.m3u8"
      assert resolution == {640, 360}

      # Target 1000 maps closer to 720p (1280) diff 280 vs 480p (842) diff 158 -> 480p
      {:ok, uri2, resolution2} = Playlist.select_variant(@master_playlist, width: 1000)
      assert uri2 == "480p/playlist.m3u8"
      assert resolution2 == {842, 480}
    end

    test "returns error if no variant found" do
      assert Playlist.select_variant("invalid") == {:error, :no_variant_found}
    end
  end

  describe "clamp_opts/2" do
    test "clamps width and height" do
      opts = [width: 2000, height: 2000, other: "keep"]
      max_res = {1000, 1000}

      clamped = Playlist.clamp_opts(opts, max_res)

      assert clamped[:width] == 1000
      assert clamped[:height] == 1000
      assert clamped[:other] == "keep"
    end

    test "does not affect opts if within bounds" do
      opts = [width: 500, height: 500]
      max_res = {1000, 1000}

      assert Playlist.clamp_opts(opts, max_res) == opts
    end

    test "returns opts as is if max resolution is nil" do
      opts = [width: 2000]
      assert Playlist.clamp_opts(opts, nil) == opts
    end

    test "ignores missing keys" do
      opts = [width: 2000]
      max_res = {1000, 500}

      clamped = Playlist.clamp_opts(opts, max_res)
      assert clamped[:width] == 1000
      refute Keyword.has_key?(clamped, :height)
    end
  end
end
