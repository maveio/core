defmodule MaveCore.EncodingBenchmark do
  @moduledoc """
  Measures encoder settings on a set of clips so that changes to the encoding
  profile can be compared on quality, size, encoding time and playback reach.

  For every clip the run prepares a lossless reference at the rendition size,
  encodes it with each `MaveCore.EncodingBenchmark.Candidate` and records:

    * file size and bitrate of the video stream
    * SSIM and PSNR against the reference, plus VMAF when FFmpeg has `libvmaf`
    * wall-clock and CPU time of the encode
    * codec profile, pixel format, keyframe spacing and the resulting
      `MaveCore.EncodingBenchmark.Compatibility` tier

  `run/1` returns a JSON-serializable map with string keys. Stored results can
  be summarized, rendered and compared again without the media, see
  `MaveCore.EncodingBenchmark.Summary` and `MaveCore.EncodingBenchmark.Report`.
  `mix perf.encoding` is the command-line entry point.
  """

  alias MaveCore.EncodingBenchmark.{Candidate, Compatibility, Corpus, Measurement}
  alias MaveCore.Flow.Steps.Support, as: StepSupport
  alias MaveCore.Media.ProductionEncodingProfile

  @schema 1
  @command_timeout_ms :timer.minutes(30)
  @max_error_length 400

  @type progress_event ::
          {:reference, String.t()}
          | {:result, map(), pos_integer(), pos_integer()}

  @doc """
  Runs the benchmark.

  Options:

    * `:clips` - clips from `MaveCore.EncodingBenchmark.Corpus` (required)
    * `:candidates` - candidates to measure (required)
    * `:work_dir` - directory for references and encodes (required)
    * `:size` - rendition size such as `"hd"`, defaults to `"hd"`
    * `:duration` - seconds measured per clip, defaults to `6`
    * `:baseline` - id of the candidate others are compared with; defaults to
      the production H.264 rendition when selected, else the first candidate
    * `:tag` - name stored with the results
    * `:keep_media` - keep references and encodes after measuring
    * `:on_progress` - function called with a `t:progress_event/0`
  """
  @spec run(keyword()) :: {:ok, map()} | {:error, term()}
  def run(opts) do
    clips = Keyword.fetch!(opts, :clips)
    candidates = Keyword.fetch!(opts, :candidates)
    work_dir = Path.expand(Keyword.fetch!(opts, :work_dir))
    size = Keyword.get(opts, :size, "hd")
    duration = Keyword.get(opts, :duration, 6)
    on_progress = Keyword.get(opts, :on_progress, fn _event -> :ok end)

    with {:ok, tools} <- tools(),
         {:ok, capabilities} <- capabilities(tools),
         {:ok, candidates, warnings} <- available_candidates(candidates, capabilities),
         {:ok, baseline} <- baseline(candidates, Keyword.get(opts, :baseline)) do
      media_dir = Path.join(work_dir, "media")
      File.mkdir_p!(media_dir)

      context = %{
        tools: tools,
        vmaf?: capabilities.vmaf?,
        size: size,
        duration: duration,
        media_dir: media_dir,
        on_progress: on_progress,
        total: length(clips) * length(candidates)
      }

      started_at = DateTime.utc_now() |> DateTime.truncate(:second)

      try do
        {clip_entries, results} = measure_clips(clips, candidates, context)

        {:ok,
         %{
           "schema" => @schema,
           "tag" => Keyword.get(opts, :tag) || Calendar.strftime(started_at, "%Y%m%dT%H%M%SZ"),
           "started_at" => DateTime.to_iso8601(started_at),
           "environment" => environment(capabilities),
           "settings" => %{
             "size" => size,
             "duration_seconds" => duration,
             "baseline" => baseline.id,
             "quality_metric" => if(capabilities.vmaf?, do: "vmaf", else: "ssim_db")
           },
           "clips" => clip_entries,
           "candidates" => Enum.map(candidates, &candidate_entry/1),
           "results" => results,
           "warnings" => warnings
         }}
      after
        unless Keyword.get(opts, :keep_media, false), do: File.rm_rf(media_dir)
      end
    end
  end

  defp tools do
    with {:ok, ffmpeg} <- StepSupport.find_ffmpeg(),
         {:ok, ffprobe} <- StepSupport.find_ffprobe() do
      {:ok, %{ffmpeg: ffmpeg, ffprobe: ffprobe}}
    end
  end

  defp capabilities(%{ffmpeg: ffmpeg}) do
    with {:ok, version} <- command(ffmpeg, ["-hide_banner", "-version"]),
         {:ok, encoders} <- command(ffmpeg, ["-hide_banner", "-encoders"]),
         {:ok, filters} <- command(ffmpeg, ["-hide_banner", "-filters"]) do
      {:ok, Measurement.capabilities(version, encoders, filters)}
    end
  end

  defp available_candidates(candidates, capabilities) do
    {available, missing} =
      Enum.split_with(candidates, &MapSet.member?(capabilities.encoders, Candidate.encoder(&1)))

    warnings =
      Enum.map(missing, fn candidate ->
        "Skipped #{candidate.id}: this FFmpeg build has no #{Candidate.encoder(candidate)} encoder"
      end)

    if available == [], do: {:error, :no_candidates_available}, else: {:ok, available, warnings}
  end

  defp baseline(candidates, nil) do
    {:ok, Enum.find(candidates, hd(candidates), &(&1.id == Candidate.baseline_id()))}
  end

  defp baseline(candidates, id) do
    case Enum.find(candidates, &(&1.id == id)) do
      nil -> {:error, {:unknown_baseline, id}}
      candidate -> {:ok, candidate}
    end
  end

  defp measure_clips(clips, candidates, context) do
    clips
    |> Enum.with_index()
    |> Enum.map_reduce([], fn {clip, clip_index}, results ->
      context.on_progress.({:reference, clip.id})
      clip_dir = Path.join(context.media_dir, clip.id)
      File.mkdir_p!(clip_dir)
      reference = Path.join(clip_dir, "reference.mp4")

      case prepare_reference(clip, reference, context) do
        {:ok, probe} ->
          offset = clip_index * length(candidates)
          measured = measure_clip(clip, candidates, {reference, probe}, clip_dir, offset, context)
          {clip_entry(clip, probe), results ++ measured}

        {:error, reason} ->
          message = "reference failed: #{describe(reason)}"
          {clip_entry(clip, %{}), results ++ Enum.map(candidates, &failure(clip, &1, message))}
      end
    end)
  end

  defp measure_clip(clip, candidates, reference, clip_dir, offset, context) do
    candidates
    |> Enum.with_index(offset + 1)
    |> Enum.map(fn {candidate, done} ->
      result = measure(clip, candidate, reference, clip_dir, context)
      context.on_progress.({:result, result, done, context.total})
      result
    end)
  end

  defp prepare_reference(clip, reference, context) do
    with {:ok, args} <- Corpus.reference_args(clip, context.size, context.duration, reference),
         {:ok, _output} <- command(context.tools.ffmpeg, args) do
      probe(context.tools.ffprobe, reference)
    end
  end

  defp measure(clip, candidate, {reference, reference_probe}, clip_dir, context) do
    output = Path.join(clip_dir, "#{candidate.id}.mp4")
    started = System.monotonic_time(:millisecond)

    with {:ok, encode_output} <-
           command(context.tools.ffmpeg, Candidate.ffmpeg_args(candidate, reference, output)),
         elapsed_ms = System.monotonic_time(:millisecond) - started,
         {:ok, %File.Stat{size: bytes}} <- File.stat(output),
         {:ok, probe} <- probe(context.tools.ffprobe, output),
         :ok <- same_frames(probe, reference_probe),
         {:ok, quality} <- quality(output, reference, clip_dir, candidate, context),
         {:ok, packets} <- command(context.tools.ffprobe, Measurement.keyframe_args(output)) do
      duration = probe.duration_seconds
      encode_seconds = max(elapsed_ms, 1) / 1000
      compatibility = Compatibility.classify(probe)

      quality
      |> stringify()
      |> Map.merge(%{
        "clip" => clip.id,
        "candidate" => candidate.id,
        "status" => "ok",
        "bytes" => bytes,
        "bitrate_kbps" => Float.round(bytes * 8 / duration / 1000, 1),
        "encode_seconds" => Float.round(encode_seconds, 2),
        "cpu_seconds" => round_optional(Measurement.parse_cpu_seconds(encode_output), 2),
        "speed" => Float.round(duration / encode_seconds, 2),
        "profile" => probe.profile,
        "level" => probe.level,
        "pixel_format" => probe.pixel_format,
        "max_keyframe_interval" => Measurement.max_keyframe_interval(packets, duration),
        "compatibility" => Atom.to_string(compatibility.tier),
        "compatibility_note" => compatibility.note
      })
    else
      {:error, reason} -> failure(clip, candidate, describe(reason))
    end
  end

  defp quality(output, reference, clip_dir, candidate, %{vmaf?: true} = context) do
    log = Path.join(clip_dir, "#{candidate.id}.vmaf.json")

    with {:ok, command_output} <-
           command(context.tools.ffmpeg, Measurement.quality_args(output, reference, log)),
         {:ok, quality} <- Measurement.parse_quality(command_output),
         {:ok, body} <- File.read(log),
         {:ok, vmaf} <- Measurement.parse_vmaf_log(body) do
      {:ok, Map.merge(quality, vmaf)}
    end
  end

  defp quality(output, reference, _clip_dir, _candidate, context) do
    with {:ok, command_output} <-
           command(context.tools.ffmpeg, Measurement.quality_args(output, reference)) do
      Measurement.parse_quality(command_output)
    end
  end

  defp probe(ffprobe, path) do
    with {:ok, output} <- command(ffprobe, Measurement.probe_args(path)) do
      Measurement.parse_probe(output)
    end
  end

  # A candidate that drops or duplicates frames cannot be compared frame by frame.
  defp same_frames(%{frames: frames}, %{frames: frames}), do: :ok

  defp same_frames(%{frames: encoded}, %{frames: reference}),
    do: {:error, {:frame_count_mismatch, encoded, reference}}

  defp command(executable, args) do
    case StepSupport.run_media_cmd(executable, args, timeout_ms: @command_timeout_ms) do
      {output, 0} when is_binary(output) -> {:ok, output}
      {output, status} when is_binary(output) -> {:error, {:exit, status, output}}
      {:error, reason} -> {:error, reason}
    end
  end

  defp failure(clip, candidate, message) do
    %{
      "clip" => clip.id,
      "candidate" => candidate.id,
      "status" => "error",
      "error" => message
    }
  end

  defp describe({:exit, status, output}) do
    tail = output |> String.trim() |> String.slice(-@max_error_length, @max_error_length)
    "exit #{status}: #{tail}"
  end

  defp describe(reason), do: inspect(reason)

  defp clip_entry(clip, probe) do
    {kind, _source} = clip.source

    %{
      "id" => clip.id,
      "description" => clip.description,
      "kind" => Atom.to_string(kind),
      "width" => probe[:width],
      "height" => probe[:height],
      "frames" => probe[:frames],
      "duration_seconds" => probe[:duration_seconds]
    }
  end

  defp candidate_entry(%Candidate{} = candidate) do
    %{
      "id" => candidate.id,
      "codec" => candidate.codec,
      "settings" => Candidate.settings(candidate),
      "description" => candidate.description,
      "origin" => Atom.to_string(candidate.origin),
      "ffmpeg_args" => Candidate.ffmpeg_args(candidate, "INPUT", "OUTPUT")
    }
  end

  defp environment(capabilities) do
    {os_family, os_name} = :os.type()

    %{
      "ffmpeg_version" => capabilities.ffmpeg_version,
      "vmaf" => capabilities.vmaf?,
      "logical_cpus" => System.schedulers_online(),
      "os" => "#{os_family}/#{os_name}",
      "architecture" => to_string(:erlang.system_info(:system_architecture)),
      "production_profile" => ProductionEncodingProfile.name()
    }
  end

  defp stringify(map), do: Map.new(map, fn {key, value} -> {Atom.to_string(key), value} end)

  defp round_optional(nil, _precision), do: nil
  defp round_optional(value, precision), do: Float.round(value, precision)
end
