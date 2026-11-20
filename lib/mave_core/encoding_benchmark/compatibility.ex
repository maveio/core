defmodule MaveCore.EncodingBenchmark.Compatibility do
  @moduledoc """
  Classifies an encode's playback reach from its probed stream properties.

  This is a static assessment of codec, profile, pixel format and container
  tag against what browsers and devices commonly decode. It is not a device
  test: use it to see which candidates can replace the universal rendition and
  which can only be offered next to one.
  """

  @type tier :: :universal | :needs_fallback | :not_web_safe
  @type t :: %{tier: tier(), note: String.t()}

  @h264_profiles ["Constrained Baseline", "Baseline", "Main", "High"]

  @spec classify(map()) :: t()
  def classify(%{codec: "h264", pixel_format: "yuv420p", profile: profile})
      when profile in @h264_profiles do
    %{tier: :universal, note: "H.264 #{profile} 8-bit 4:2:0 plays in every current browser"}
  end

  def classify(%{codec: "h264"} = probe) do
    %{
      tier: :not_web_safe,
      note:
        "H.264 #{probe[:profile]} #{probe[:pixel_format]} is not decoded by most browsers and hardware"
    }
  end

  def classify(%{codec: "hevc", pixel_format: format, codec_tag: "hvc1"})
      when format in ["yuv420p", "yuv420p10le"] do
    %{
      tier: :needs_fallback,
      note: "HEVC plays in Safari and on devices with a hardware decoder; keep an H.264 rendition"
    }
  end

  def classify(%{codec: "hevc", pixel_format: format})
      when format in ["yuv420p", "yuv420p10le"] do
    %{tier: :not_web_safe, note: "HEVC without the hvc1 tag does not play on Apple devices"}
  end

  def classify(%{codec: "av1", pixel_format: format})
      when format in ["yuv420p", "yuv420p10le"] do
    %{
      tier: :needs_fallback,
      note:
        "AV1 plays in Chrome, Edge and Firefox, and in Safari only with a hardware decoder; keep an H.264 rendition"
    }
  end

  def classify(probe) do
    %{
      tier: :not_web_safe,
      note: "#{probe[:codec]} #{probe[:pixel_format]} is outside the formats browsers decode"
    }
  end
end
