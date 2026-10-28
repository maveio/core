defmodule MaveCore.Media.HlsBandwidthTest do
  use ExUnit.Case, async: true

  alias MaveCore.Media.HlsBandwidth

  test "measures average and peak from segment bytes and durations" do
    playlist =
      "#EXTM3U\n#EXT-X-TARGETDURATION:6\n#EXTINF:6.000,\nsegment_000.m4s\n#EXTINF:6.000,\nsegment_001.m4s\n#EXTINF:1.000,\nsegment_002.m4s\n"

    files = [
      %{"name" => "init.mp4", "file_size" => 1_000_000},
      %{"name" => "segment_000.m4s", "file_size" => 750_000},
      %{"name" => "segment_001.m4s", "file_size" => 1_500_000},
      %{"name" => "segment_002.m4s", "file_size" => 500_000}
    ]

    assert HlsBandwidth.measure(playlist, files) == %{
             bandwidth: ceil(2_000_000 * 8 / 7),
             average_bandwidth: ceil(2_750_000 * 8 / 13)
           }
  end

  test "supports CRLF playlists and clips shorter than half a target duration" do
    playlist = "#EXTM3U\r\n#EXT-X-TARGETDURATION:6\r\n#EXTINF:1.000,\r\nsegment_000.m4s\r\n"
    files = [%{"name" => "segment_000.m4s", "file_size" => 1000}]
    assert HlsBandwidth.measure(playlist, files) == %{bandwidth: 8000, average_bandwidth: 8000}
  end

  test "does not invent measurements for incomplete or invalid metadata" do
    for playlist <- [
          "#EXTM3U\n",
          "#EXT-X-TARGETDURATION:6\n#EXTINF:0,\nsegment_000.m4s\n",
          "#EXT-X-TARGETDURATION:6\n#EXTINF:6,\nmissing.m4s\n"
        ] do
      assert HlsBandwidth.measure(playlist, []) == %{}
    end
  end
end
