defmodule MaveCore.Media.ProductionEncodingProfile do
  @moduledoc """
  The single video encoding contract used by production boosters.

  This is an internal Core-to-booster protocol version, not a flow-template
  version. The built-in `publish_default` definition records the contract name
  so a contract change produces a new immutable flow version when presets sync.

  Local development and explicit FLAME fallback keep their local FFmpeg
  profiles. Production booster callers must build requests through this module
  so codec settings cannot silently drift between flow steps or spaces.
  """

  alias MaveCore.Media.RenditionSizing

  @name "mave-production-v2"
  @audio_bitrate "128k"
  @h264_bitrates %{
    "sd" => "2M",
    "hd" => "4M",
    "fhd" => "8M",
    "qhd" => "12M",
    "uhd" => "16M"
  }
  @hevc_bitrates %{
    "sd" => "1M",
    "hd" => "2M",
    "fhd" => "4M",
    "qhd" => "6M",
    "uhd" => "8M"
  }
  @svt_av1_params "pin-threads=0:set-thread-priority=0:no-set-thread-priority=1:hierarchical-levels=4:tile-threads=0:log-level=1:tune=0"

  @type profile :: %{
          name: String.t(),
          request_options: keyword(),
          capacity_video_bitrate: String.t(),
          encoder: map()
        }

  def name, do: @name

  @spec h264_ladder(String.t(), boolean(), pos_integer(), pos_integer() | nil) ::
          {:ok, profile()} | {:error, term()}
  def h264_ladder(size, include_audio?, gop_frames, width_override \\ nil) do
    with {:ok, width} <- profile_width(size, width_override),
         {:ok, bitrate} <- fetch_bitrate(@h264_bitrates, size) do
      {:ok,
       build_profile(
         [
           codec: "h264",
           width: width,
           video_bitrate: bitrate,
           audio_bitrate: @audio_bitrate,
           preset: "veryfast",
           include_audio: include_audio?,
           keyframe_interval_seconds: 2,
           gop_frames: max(gop_frames, 1)
         ],
         bitrate,
         %{"codec" => "h264", "preset" => "veryfast", "rate_control" => "abr"}
       )}
    end
  end

  @spec video_rendition(String.t(), String.t(), non_neg_integer(), pos_integer() | nil) ::
          {:ok, profile()} | {:error, term()}
  def video_rendition(codec, size, keyframe_interval, width_override \\ nil) do
    with {:ok, width} <- profile_width(size, width_override),
         {:ok, capacity_bitrate} <- fetch_bitrate(@h264_bitrates, size),
         {:ok, codec_options, encoder} <- codec_options(codec, size, keyframe_interval) do
      common = [
        codec: codec,
        width: width,
        audio_bitrate: @audio_bitrate,
        include_audio: include_audio?(codec, keyframe_interval)
      ]

      {:ok, build_profile(common ++ codec_options, capacity_bitrate, encoder)}
    end
  end

  defp profile_width(size, nil), do: RenditionSizing.target_long_edge(size)

  defp profile_width(size, width_override)
       when is_integer(width_override) and width_override > 0 do
    with {:ok, target_long_edge} <- RenditionSizing.target_long_edge(size) do
      {:ok, min(width_override, target_long_edge)}
    end
  end

  defp profile_width(_size, width_override),
    do: {:error, {:invalid_width_override, width_override}}

  defp codec_options("h264", size, 2) do
    with {:ok, bitrate} <- fetch_bitrate(@h264_bitrates, size) do
      {:ok,
       [
         video_bitrate: bitrate,
         video_crf: 23,
         preset: "medium",
         gop_frames: 2,
         max_duration_seconds: 10
       ],
       %{
         "codec" => "h264",
         "preset" => "medium",
         "rate_control" => "crf+abr",
         "crf" => 23
       }}
    end
  end

  defp codec_options("h264", size, _keyframe_interval) do
    with {:ok, bitrate} <- fetch_bitrate(@h264_bitrates, size) do
      {:ok,
       [
         video_bitrate: bitrate,
         preset: "faster",
         tune: "grain",
         keyframe_interval_seconds: 2
       ],
       %{
         "codec" => "h264",
         "preset" => "faster",
         "tune" => "grain",
         "rate_control" => "abr"
       }}
    end
  end

  defp codec_options("hevc", size, 2) do
    with {:ok, bitrate} <- fetch_bitrate(@hevc_bitrates, size) do
      {:ok,
       [
         video_bitrate: bitrate,
         preset: "medium",
         gop_frames: 2,
         max_duration_seconds: 10
       ], %{"codec" => "hevc", "preset" => "medium", "rate_control" => "abr"}}
    end
  end

  defp codec_options("hevc", _size, _keyframe_interval) do
    {:ok,
     [
       video_crf: 24,
       preset: "medium",
       tune: "grain",
       max_duration_seconds: 60
     ],
     %{
       "codec" => "hevc",
       "preset" => "medium",
       "tune" => "grain",
       "rate_control" => "crf",
       "crf" => 24
     }}
  end

  defp codec_options("av1", _size, keyframe_interval) do
    {:ok,
     [
       video_crf: 26,
       preset: "slow",
       svt_av1_params: @svt_av1_params,
       gop_frames: max(keyframe_interval, 1),
       max_duration_seconds: 60
     ],
     %{
       "codec" => "av1",
       "preset" => "6",
       "rate_control" => "crf",
       "crf" => 26,
       "svt_av1_params" => @svt_av1_params
     }}
  end

  defp codec_options(codec, _size, _keyframe_interval),
    do: {:error, {:unsupported_codec, codec}}

  defp build_profile(request_options, capacity_video_bitrate, encoder) do
    %{
      name: @name,
      request_options: [encoding_profile: @name] ++ request_options,
      capacity_video_bitrate: capacity_video_bitrate,
      encoder: Map.put(encoder, "profile", @name)
    }
  end

  defp include_audio?(_codec, 2), do: false
  defp include_audio?(codec, _keyframe_interval) when codec in ["hevc", "av1"], do: false
  defp include_audio?(_codec, _keyframe_interval), do: true

  defp fetch_bitrate(bitrates, size) do
    case Map.fetch(bitrates, size) do
      {:ok, bitrate} -> {:ok, bitrate}
      :error -> {:error, {:unsupported_size, size}}
    end
  end
end
