defmodule MaveCore.EncodingBenchmark.Measurement do
  @moduledoc """
  FFmpeg and FFprobe invocations used to measure an encode, and the parsers for
  their output.

  Quality is measured against the lossless reference with FFmpeg's `ssim` and
  `psnr` filters, and with `libvmaf` when the local FFmpeg build includes it.
  Both inputs have the same dimensions and frame count by construction.
  """

  # Encoders tag the color range differently; compare pixels, not metadata.
  @normalize "setparams=range=tv,settb=AVTB,setpts=PTS-STARTPTS"

  @doc "Parses `ffmpeg -version`, `-encoders` and `-filters` output into capabilities."
  @spec capabilities(String.t(), String.t(), String.t()) :: map()
  def capabilities(version_output, encoders_output, filters_output) do
    %{
      ffmpeg_version:
        case Regex.run(~r/ffmpeg version (\S+)/, version_output) do
          [_, version] -> version
          _other -> "unknown"
        end,
      encoders:
        ~r/^\s*V\S*\s+(\S+)/m
        |> Regex.scan(encoders_output)
        |> MapSet.new(fn [_, name] -> name end),
      vmaf?: Regex.match?(~r/^\s*\S+\s+libvmaf\s/m, filters_output)
    }
  end

  @doc """
  Builds the arguments that compare `encoded` with `reference`.

  Pass `vmaf_log` to add a `libvmaf` pass that writes its JSON log there.
  """
  @spec quality_args(Path.t(), Path.t(), Path.t() | nil) :: [String.t()]
  def quality_args(encoded, reference, vmaf_log \\ nil) do
    reference_count = if vmaf_log, do: 3, else: 2
    labels = Enum.map_join(1..reference_count, &"[r#{&1}]")

    graph =
      "[0:v]#{@normalize}[d0];" <>
        "[1:v]#{@normalize},split=#{reference_count}#{labels};" <>
        "[d0][r1]ssim[d1];[d1][r2]psnr" <>
        if(vmaf_log, do: "[d2];[d2][r3]libvmaf=log_fmt=json:log_path=#{vmaf_log}", else: "")

    [
      "-hide_banner",
      "-nostats",
      "-i",
      encoded,
      "-i",
      reference,
      "-lavfi",
      graph,
      "-f",
      "null",
      "-"
    ]
  end

  @doc "Extracts SSIM (0..1 and dB) and PSNR (dB) from the quality pass output."
  @spec parse_quality(String.t()) :: {:ok, map()} | {:error, :quality_metrics_not_found}
  def parse_quality(output) do
    with [_, ssim, ssim_db] <-
           Regex.run(~r/SSIM .*All:([0-9.]+) \(([0-9.]+|inf)\)/, output),
         [_, psnr] <- Regex.run(~r/PSNR .*average:([0-9.]+|inf)/, output) do
      {:ok, %{ssim: number(ssim), ssim_db: number(ssim_db), psnr: number(psnr)}}
    else
      _other -> {:error, :quality_metrics_not_found}
    end
  end

  @doc "Reads the mean and minimum VMAF score from a libvmaf JSON log."
  @spec parse_vmaf_log(String.t()) :: {:ok, map()} | {:error, :vmaf_scores_not_found}
  def parse_vmaf_log(body) do
    case Jason.decode(body) do
      {:ok, %{"pooled_metrics" => %{"vmaf" => %{"mean" => mean, "min" => min}}}}
      when is_number(mean) and is_number(min) ->
        {:ok, %{vmaf: mean / 1, vmaf_min: min / 1}}

      _other ->
        {:error, :vmaf_scores_not_found}
    end
  end

  @doc "Returns the CPU seconds FFmpeg reports with `-benchmark`, if present."
  @spec parse_cpu_seconds(String.t()) :: float() | nil
  def parse_cpu_seconds(output) do
    case Regex.run(~r/bench: utime=([0-9.]+)s stime=([0-9.]+)s/, output) do
      [_, user, system] -> String.to_float(user) + String.to_float(system)
      _other -> nil
    end
  end

  @spec probe_args(Path.t()) :: [String.t()]
  def probe_args(path) do
    ["-v", "error", "-select_streams", "v:0"] ++
      ["-show_entries", "stream=codec_name,profile,level,pix_fmt,width,height,codec_tag_string"] ++
      ["-show_entries", "stream=nb_frames:format=duration", "-of", "json", path]
  end

  @spec parse_probe(String.t()) :: {:ok, map()} | {:error, :invalid_probe_output}
  def parse_probe(output) do
    with {:ok, %{"streams" => [stream | _], "format" => %{"duration" => duration}}} <-
           Jason.decode(output),
         {seconds, _rest} when seconds > 0 <- Float.parse(duration) do
      {:ok,
       %{
         codec: stream["codec_name"],
         profile: stream["profile"],
         level: stream["level"],
         pixel_format: stream["pix_fmt"],
         width: stream["width"],
         height: stream["height"],
         codec_tag: stream["codec_tag_string"],
         frames: parse_integer(stream["nb_frames"]),
         duration_seconds: seconds
       }}
    else
      _other -> {:error, :invalid_probe_output}
    end
  end

  @spec keyframe_args(Path.t()) :: [String.t()]
  def keyframe_args(path) do
    ["-v", "error", "-select_streams", "v:0"] ++
      ["-show_entries", "packet=pts_time,flags", "-of", "csv=p=0", path]
  end

  @doc """
  Returns the longest stretch without a keyframe, in seconds.

  Segmented delivery needs keyframes at segment boundaries, so this is the
  shortest segment duration the encode can be packaged with.
  """
  @spec max_keyframe_interval(String.t(), float()) :: float() | nil
  def max_keyframe_interval(packets_output, duration_seconds) do
    keyframes =
      packets_output
      |> String.split("\n", trim: true)
      |> Enum.flat_map(fn line ->
        with [time, flags | _] <- String.split(line, ","),
             true <- String.starts_with?(flags, "K"),
             {seconds, _rest} <- Float.parse(time) do
          [seconds]
        else
          _other -> []
        end
      end)
      |> Enum.sort()

    case keyframes do
      [] ->
        nil

      _keyframes ->
        (keyframes ++ [duration_seconds])
        |> Enum.chunk_every(2, 1, :discard)
        |> Enum.map(fn [from, to] -> to - from end)
        |> Enum.max()
        |> Float.round(3)
    end
  end

  # FFmpeg prints `inf` when the encode is identical to the reference.
  defp number("inf"), do: nil

  defp number(value) do
    {number, _rest} = Float.parse(value)
    number
  end

  defp parse_integer(value) when is_binary(value) do
    case Integer.parse(value) do
      {integer, _rest} -> integer
      :error -> nil
    end
  end

  defp parse_integer(_value), do: nil
end
