defmodule MaveCore.EncodingBenchmark.Candidate do
  @moduledoc """
  One set of encoder settings measured by the encoding benchmark.

  The `production-*` candidates are derived from
  `MaveCore.Media.ProductionEncodingProfile`, so the baseline follows the
  production contract instead of a copy that can drift. `ffmpeg_args/3` mirrors
  the CPU path of the encoding booster (`videoFFmpegArgs` in
  `deploy/encoding-booster/encoder/main.go`) without its source handling,
  scaling and sandbox thread-pool options: benchmark references are already
  prepared at the rendition size.

  Additional candidates come from the built-in exploration set or from a JSON
  file, see `load_file/1`.
  """

  alias MaveCore.Media.ProductionEncodingProfile

  @enforce_keys [:id, :codec]
  defstruct [
    :id,
    :codec,
    :preset,
    :crf,
    :bitrate,
    :maxrate,
    :bufsize,
    :tune,
    :params,
    :gop_frames,
    :description,
    keyframe_interval_seconds: 2,
    origin: :custom
  ]

  @type t :: %__MODULE__{}

  @encoders %{"h264" => "libx264", "hevc" => "libx265", "av1" => "libsvtav1"}
  @params_options %{
    "h264" => "-x264-params",
    "hevc" => "-x265-params",
    "av1" => "-svtav1-params"
  }
  # Same translation the booster applies to the shared preset vocabulary.
  @svt_av1_presets %{
    "ultrafast" => "12",
    "superfast" => "11",
    "veryfast" => "10",
    "faster" => "9",
    "fast" => "8",
    "medium" => "7",
    "slow" => "6",
    "slower" => "5",
    "veryslow" => "4",
    "placebo" => "3"
  }
  @presets Map.keys(@svt_av1_presets)
  @tunes ~w(film animation grain stillimage fastdecode zerolatency psnr ssim)
  @rate_pattern ~r/\A[1-9][0-9]*[kM]\z/
  @id_pattern ~r/\A[a-z0-9][a-z0-9._-]{0,63}\z/
  @params_pattern ~r/\A[A-Za-z0-9=:._,+-]{1,512}\z/
  @production_gop_frames 250
  @baseline_id "production-h264"

  def baseline_id, do: @baseline_id
  def encoder(%__MODULE__{codec: codec}), do: Map.fetch!(@encoders, codec)

  @doc """
  Returns the candidates measured when none are selected: the three production
  renditions for `size` and a small exploration set around them.
  """
  @spec defaults(String.t()) :: {:ok, [t()]} | {:error, term()}
  def defaults(size) do
    with {:ok, production} <- production(size) do
      h264 = Enum.find(production, &(&1.id == @baseline_id))
      {:ok, production ++ exploration(h264)}
    end
  end

  @doc "Returns the candidates that encode what production publishes for `size`."
  @spec production(String.t()) :: {:ok, [t()]} | {:error, term()}
  def production(size) do
    with {:ok, h264} <- ProductionEncodingProfile.h264_ladder(size, false, @production_gop_frames),
         {:ok, hevc} <-
           ProductionEncodingProfile.video_rendition("hevc", size, @production_gop_frames),
         {:ok, av1} <-
           ProductionEncodingProfile.video_rendition("av1", size, @production_gop_frames) do
      {:ok,
       [
         from_profile(@baseline_id, h264, "HLS ladder rendition (#{h264.name})"),
         from_profile("production-hevc", hevc, "HEVC rendition (#{hevc.name})"),
         from_profile("production-av1", av1, "AV1 rendition (#{av1.name})")
       ]}
    end
  end

  # Variations of the production H.264 ladder under the same bitrate cap: a
  # higher CRF, and slower presets that trade encoding time for size.
  defp exploration(%__MODULE__{crf: crf} = h264) do
    [
      {"h264-crf#{crf + 2}", crf + 2, h264.preset},
      {"h264-crf#{crf + 4}", crf + 4, h264.preset},
      {"h264-medium", crf, "medium"},
      {"h264-slow", crf, "slow"},
      {"h264-slow-crf#{crf + 2}", crf + 2, "slow"}
    ]
    |> Enum.map(fn {id, crf, preset} ->
      %{
        h264
        | id: id,
          crf: crf,
          preset: preset,
          origin: :builtin,
          description: "Ladder bitrate cap, CRF #{crf}, preset #{preset}"
      }
    end)
  end

  defp from_profile(id, %{request_options: options}, description) do
    %__MODULE__{
      id: id,
      codec: Keyword.fetch!(options, :codec),
      preset: Keyword.get(options, :preset),
      crf: Keyword.get(options, :video_crf),
      bitrate: Keyword.get(options, :video_bitrate),
      maxrate: Keyword.get(options, :video_maxrate),
      bufsize: Keyword.get(options, :video_bufsize),
      tune: Keyword.get(options, :tune),
      params: Keyword.get(options, :svt_av1_params),
      gop_frames: Keyword.get(options, :gop_frames),
      keyframe_interval_seconds: Keyword.get(options, :keyframe_interval_seconds),
      description: description,
      origin: :production
    }
  end

  @doc """
  Loads candidates from a JSON file containing a list of objects.

  Supported keys: `id`, `codec` (`h264`, `hevc`, `av1`), `preset`, `crf`,
  `bitrate`, `maxrate`, `bufsize`, `tune`, `params` (encoder-private options),
  `gop_frames`, `keyframe_interval_seconds` and `description`. A list of `crf`
  values expands into one candidate per value, named `<id>-crf<value>`.
  """
  @spec load_file(Path.t()) :: {:ok, [t()]} | {:error, term()}
  def load_file(path) do
    with {:ok, body} <- File.read(path),
         {:ok, decoded} <- Jason.decode(body) do
      from_entries(decoded)
    else
      {:error, %Jason.DecodeError{} = error} ->
        {:error, {:invalid_json, Exception.message(error)}}

      {:error, reason} ->
        {:error, {:unreadable_candidates_file, reason}}
    end
  end

  @doc false
  def from_entries(entries) when is_list(entries) and entries != [] do
    entries
    |> Enum.reduce_while({:ok, []}, fn entry, {:ok, acc} ->
      case from_entry(entry) do
        {:ok, candidates} -> {:cont, {:ok, acc ++ candidates}}
        {:error, reason} -> {:halt, {:error, reason}}
      end
    end)
    |> reject_duplicates()
  end

  def from_entries(_other), do: {:error, :candidates_must_be_a_non_empty_list}

  defp from_entry(%{"crf" => crfs} = entry) when is_list(crfs) and crfs != [] do
    crfs
    |> Enum.reduce_while({:ok, []}, fn crf, {:ok, acc} ->
      id = "#{entry["id"]}-crf#{crf}"

      case build(%{entry | "crf" => crf, "id" => id}) do
        {:ok, candidate} -> {:cont, {:ok, acc ++ [candidate]}}
        {:error, reason} -> {:halt, {:error, reason}}
      end
    end)
  end

  defp from_entry(%{} = entry) do
    with {:ok, candidate} <- build(entry), do: {:ok, [candidate]}
  end

  defp from_entry(_other), do: {:error, :candidate_must_be_an_object}

  defp build(entry) do
    codec = entry["codec"]

    with {:ok, id} <- validate(entry, "id", &(is_binary(&1) and &1 =~ @id_pattern)),
         :ok <- require_value(id, "id"),
         :ok <- check(is_map_key(@encoders, codec), {:unsupported_codec, id, codec}),
         {:ok, preset} <- validate(entry, "preset", &(&1 in @presets)),
         {:ok, crf} <- validate(entry, "crf", &(is_integer(&1) and &1 in 0..63)),
         {:ok, bitrate} <- validate(entry, "bitrate", &rate?/1),
         {:ok, maxrate} <- validate(entry, "maxrate", &rate?/1),
         {:ok, bufsize} <- validate(entry, "bufsize", &rate?/1),
         {:ok, tune} <- validate(entry, "tune", &(&1 in @tunes)),
         {:ok, params} <- validate(entry, "params", &(is_binary(&1) and &1 =~ @params_pattern)),
         {:ok, gop} <- validate(entry, "gop_frames", &(is_integer(&1) and &1 > 0)),
         {:ok, keyframes} <-
           validate(entry, "keyframe_interval_seconds", &(is_integer(&1) and &1 in 0..30)),
         {:ok, description} <- validate(entry, "description", &is_binary/1),
         :ok <- check(is_nil(maxrate) == is_nil(bufsize), {:maxrate_requires_bufsize, id}),
         :ok <- check(not (is_nil(crf) and is_nil(bitrate)), {:missing_rate_control, id}) do
      {:ok,
       %__MODULE__{
         id: id,
         codec: codec,
         preset: preset || "medium",
         crf: crf,
         bitrate: bitrate,
         maxrate: maxrate,
         bufsize: bufsize,
         tune: tune,
         params: params,
         gop_frames: gop,
         keyframe_interval_seconds: if(is_nil(keyframes), do: 2, else: keyframes),
         description: description
       }}
    end
  end

  defp validate(entry, key, valid?) do
    case Map.get(entry, key) do
      nil ->
        {:ok, nil}

      value ->
        if valid?.(value), do: {:ok, value}, else: {:error, {:invalid_candidate, key, value}}
    end
  end

  defp require_value(nil, key), do: {:error, {:missing_candidate_key, key}}
  defp require_value(_value, _key), do: :ok

  defp check(true, _reason), do: :ok
  defp check(false, reason), do: {:error, reason}

  defp rate?(value), do: is_binary(value) and value =~ @rate_pattern

  defp reject_duplicates({:ok, candidates}) do
    ids = Enum.map(candidates, & &1.id)

    case ids -- Enum.uniq(ids) do
      [] -> {:ok, candidates}
      [duplicate | _rest] -> {:error, {:duplicate_candidate, duplicate}}
    end
  end

  defp reject_duplicates(error), do: error

  @doc """
  Builds the FFmpeg arguments that encode `input` to `output` with `candidate`.

  The output is video only, so its size is the size of the video stream.
  """
  @spec ffmpeg_args(t(), Path.t(), Path.t()) :: [String.t()]
  def ffmpeg_args(%__MODULE__{} = candidate, input, output) do
    ["-y", "-hide_banner", "-benchmark", "-i", input, "-map_metadata", "-1", "-map", "0:v:0"] ++
      ["-c:v", encoder(candidate), "-preset", encoder_preset(candidate)] ++
      tune_args(candidate) ++
      option("-b:v", candidate.bitrate) ++
      rate_cap_args(candidate) ++
      option("-crf", candidate.crf) ++
      option(Map.fetch!(@params_options, candidate.codec), candidate.params) ++
      ["-pix_fmt", "yuv420p", "-threads", "0"] ++
      keyframe_args(candidate) ++
      option("-g", candidate.gop_frames) ++
      ["-an"] ++
      if(candidate.codec == "hevc", do: ["-tag:v", "hvc1"], else: []) ++
      ["-movflags", "+faststart", output]
  end

  @doc "Summarizes the rate control and speed settings for tables and reports."
  @spec settings(t()) :: String.t()
  def settings(%__MODULE__{} = candidate) do
    [
      encoder(candidate),
      "preset #{encoder_preset(candidate)}",
      candidate.crf && "CRF #{candidate.crf}",
      candidate.bitrate && "#{candidate.bitrate} target",
      candidate.maxrate && "#{candidate.maxrate} cap",
      candidate.tune && "tune #{candidate.tune}"
    ]
    |> Enum.filter(& &1)
    |> Enum.join(", ")
  end

  defp encoder_preset(%__MODULE__{codec: "av1", preset: preset}),
    do: Map.get(@svt_av1_presets, preset || "medium", "7")

  defp encoder_preset(%__MODULE__{preset: preset}), do: preset || "medium"

  # SVT-AV1 has no x264-style tunes; the booster drops them for AV1 as well.
  defp tune_args(%__MODULE__{codec: "av1"}), do: []
  defp tune_args(%__MODULE__{tune: tune}), do: option("-tune", tune)

  defp rate_cap_args(%__MODULE__{maxrate: nil}), do: []

  defp rate_cap_args(%__MODULE__{maxrate: maxrate, bufsize: bufsize}),
    do: ["-maxrate", maxrate, "-bufsize", bufsize]

  defp keyframe_args(%__MODULE__{keyframe_interval_seconds: seconds})
       when is_integer(seconds) and seconds > 0,
       do: ["-force_key_frames", "expr:gte(t,n_forced*#{seconds})"]

  defp keyframe_args(_candidate), do: []

  defp option(_name, nil), do: []
  defp option(name, value), do: [name, to_string(value)]
end
