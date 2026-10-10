defmodule MaveCore.Playback.MediaTest do
  use ExUnit.Case, async: true
  alias MaveCore.Playback.Media

  test "root playlists resolve rendition, audio and subtitle paths without a dot prefix" do
    for path <- [
          "h264_sd_hls/playlist.m3u8",
          "audio_hls/playlist.m3u8",
          "subtitle_en_hls/playlist.m3u8"
        ] do
      assert {:ok, ^path} = Media.resolve_path(path, "video", ".")
    end

    assert {:ok, "h264_sd_hls/segment0.ts"} =
             Media.resolve_path("segment0.ts", "video", "h264_sd_hls")
  end

  test "media paths cannot escape the authorized video prefix" do
    for path <- [
          "../other/playlist.m3u8",
          "/other/playlist.m3u8",
          "https://example.com/other/playlist.m3u8",
          "%2e%2e/other"
        ] do
      assert {:error, :invalid_path} = Media.resolve_path(path, "video", ".")
    end
  end
end
