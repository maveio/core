defmodule MaveCore.EncodingBenchmark.CompatibilityTest do
  use ExUnit.Case, async: true

  alias MaveCore.EncodingBenchmark.Compatibility

  defp tier(probe), do: Compatibility.classify(probe).tier

  test "8-bit 4:2:0 H.264 in a browser profile is universal" do
    assert tier(%{codec: "h264", profile: "High", pixel_format: "yuv420p"}) == :universal
    assert tier(%{codec: "h264", profile: "Main", pixel_format: "yuv420p"}) == :universal
  end

  test "H.264 outside browser profiles is not web-safe" do
    assert tier(%{codec: "h264", profile: "High 10", pixel_format: "yuv420p10le"}) ==
             :not_web_safe

    assert tier(%{codec: "h264", profile: "High 4:4:4 Predictive", pixel_format: "yuv444p"}) ==
             :not_web_safe
  end

  test "HEVC and AV1 need a universal rendition next to them" do
    assert tier(%{codec: "hevc", pixel_format: "yuv420p", codec_tag: "hvc1"}) == :needs_fallback
    assert tier(%{codec: "av1", pixel_format: "yuv420p", codec_tag: "av01"}) == :needs_fallback
  end

  test "HEVC without the hvc1 tag is not web-safe" do
    assert %{tier: :not_web_safe, note: note} =
             Compatibility.classify(%{codec: "hevc", pixel_format: "yuv420p", codec_tag: "hev1"})

    assert note =~ "hvc1"
  end

  test "unknown codecs and pixel formats are not web-safe" do
    assert tier(%{codec: "vp9", pixel_format: "yuv420p"}) == :not_web_safe
    assert tier(%{codec: "av1", pixel_format: "yuv444p"}) == :not_web_safe
  end
end
