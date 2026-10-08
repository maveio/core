defmodule MaveCore.Flow.Steps.MediaGenerateSegmentsStep do
  @moduledoc """
  Produces segment thumbnails (`thumbnail_0.jpg`..`thumbnail_5.jpg`) for seek previews.

  Modes:
  - `auto` (default): FFmpeg for normal sources; copy-mode only for inline `source_body`
  - `copy`: compatibility mode for inline `source_body`
  - `ffmpeg`: always use FFmpeg thumbnail extraction
  """
  @behaviour MaveCore.Flow.Step

  alias MaveCore.EncodingBooster
  alias MaveCore.Flow.Steps.Support, as: StepSupport
  alias MaveCore.Media.RenditionSizing
  alias MaveCore.Media.Storage

  @supported_modes ~w(auto copy ffmpeg)
  @default_count 6

  @impl true
  def run(step_definition, context) do
    run_input = Map.get(context, :run_input, %{})
    dependency_outputs = Map.get(context, :dependency_outputs, %{})
    params = Map.get(step_definition, "params", %{})
    step_id = Map.get(step_definition, "id", "segments")

    source_url = Map.get(run_input, "input_url") || Map.get(run_input, "source_url")
    space_hash = Map.get(run_input, "space_hash")
    embed_hash = Map.get(run_input, "embed_hash")
    version = Map.get(run_input, "version", 0)
    region = Map.get(run_input, "region")
    codec = StepSupport.normalize_param_downcase(Map.get(params, "codec"), "jpg")
    size = StepSupport.normalize_param_downcase(Map.get(params, "size"), "sd")
    count = normalize_positive_integer(Map.get(params, "count"), @default_count)
    mode = StepSupport.normalize_mode(run_input, "media_generate_segments_mode", @supported_modes)
    strict? = StepSupport.strict_enabled?(params, run_input, "media_generate_segments_strict")
    storage_adapter = Application.get_env(:mave_core, :flow_storage_adapter, Storage)
    bucket = Storage.bucket_for_space(space_hash, region)

    progress =
      StepSupport.ffmpeg_progress(Map.get(context, :progress_reporter), %{
        stage: "generate_segments",
        step_id: step_id,
        codec: codec,
        size: size,
        container: codec
      })

    if StepSupport.inspect_reports_no_video?(dependency_outputs) do
      {:ok, skipped_output(step_id, codec, size, "no video stream"), []}
    else
      generate_segments(
        run_input,
        dependency_outputs,
        source_url,
        space_hash,
        embed_hash,
        version,
        region,
        codec,
        size,
        count,
        mode,
        strict?,
        storage_adapter,
        bucket,
        step_id,
        progress,
        Map.get(context, :progress_reporter),
        Map.get(context, :encoding_booster_dispatch),
        Map.get(context, :encoding_booster_fallback_code)
      )
    end
  end

  # credo:disable-for-next-line Credo.Check.Refactor.FunctionArity
  defp generate_segments(
         run_input,
         dependency_outputs,
         source_url,
         space_hash,
         embed_hash,
         version,
         region,
         codec,
         size,
         count,
         mode,
         strict?,
         storage_adapter,
         bucket,
         step_id,
         progress,
         progress_reporter,
         encoding_booster_dispatch,
         encoding_booster_fallback_code
       ) do
    with {:ok, space_hash} <- StepSupport.require_binary(space_hash, :space_hash),
         {:ok, embed_hash} <- StepSupport.require_binary(embed_hash, :embed_hash),
         {:ok, source_url} <- StepSupport.require_binary(source_url, :source_url),
         {:ok, uploaded, total_size, actual_mode, mode_meta} <-
           generate_and_put_segments(
             %{
               bucket: bucket,
               codec: codec,
               count: count,
               dependency_outputs: dependency_outputs,
               dispatch: encoding_booster_dispatch,
               embed_hash: embed_hash,
               fallback_code: encoding_booster_fallback_code,
               progress_reporter: progress_reporter,
               region: region,
               run_input: run_input,
               source_url: source_url,
               step_id: step_id,
               storage_adapter: storage_adapter,
               version: version
             },
             mode,
             run_input,
             source_url,
             dependency_outputs,
             codec,
             count,
             progress
           ) do
      rendition = segments_rendition(codec, size, uploaded, total_size)

      output =
        %{
          "status" => "ok",
          "step_type" => "media.generate_segments",
          "mode" => actual_mode,
          "step_id" => step_id,
          "codec" => codec,
          "container" => codec,
          "size" => size,
          "count" => length(uploaded),
          "segments" => uploaded,
          "file_size" => total_size,
          "rendition" => rendition,
          "renditions" => [rendition]
        }
        |> Map.merge(mode_meta)

      artifacts =
        Enum.map(uploaded, fn segment ->
          %{
            name: "thumbnail_#{segment["index"]}",
            uri: segment["uri"],
            media_type: media_type(codec),
            size_bytes: segment["file_size"],
            metadata: %{
              "type" => "image",
              "role" => "segments",
              "index" => segment["index"],
              "timestamp_seconds" => segment["timestamp_seconds"],
              "codec" => codec,
              "space_hash" => space_hash,
              "embed_hash" => embed_hash,
              "version" => StepSupport.normalize_version(version)
            }
          }
        end)

      {:ok, output, artifacts}
    else
      {:error, {:encoding_booster_fallback_required, _code, _reason} = reason} ->
        {:error, reason}

      {:error, reason} when strict? ->
        {:error, {:media_generate_segments_failed, reason}}

      {:error, reason} ->
        {:ok, unavailable_output(step_id, codec, size, reason), []}
    end
  end

  defp generate_and_put_segments(
         %{dispatch: :direct} = context,
         _mode,
         _run_input,
         _source_url,
         _dependency_outputs,
         _codec,
         _count,
         _progress
       ) do
    generate_segments_with_booster(context)
  end

  defp generate_and_put_segments(
         context,
         mode,
         run_input,
         source_url,
         dependency_outputs,
         codec,
         count,
         progress
       ) do
    with {:ok, frames, actual_mode, mode_meta} <-
           build_segments(
             mode,
             run_input,
             source_url,
             dependency_outputs,
             codec,
             count,
             progress
           ),
         {:ok, uploaded, total_size} <-
           put_segments(
             context.storage_adapter,
             context.bucket,
             context.embed_hash,
             context.version,
             codec,
             frames,
             context.region
           ) do
      {:ok, uploaded, total_size, actual_mode,
       maybe_put_fallback(mode_meta, context.fallback_code)}
    end
  end

  defp generate_segments_with_booster(context) do
    duration = media_duration_seconds(context.dependency_outputs, 6.0)

    with {:ok, input_url} <-
           StepSupport.encoding_booster_input_url(
             context.run_input,
             context.source_url,
             context.dependency_outputs,
             prefer_video_rendition: true,
             preferred_video_step_id: "video_h264_sd",
             preferred_video_sizes: ["sd"],
             preferred_video_codec: "h264"
           ),
         {:ok, assets} <- start_segment_uploads(context, duration) do
      upload_segments_with_booster(context, input_url, duration, assets)
    else
      {:error, reason} -> booster_error(reason)
    end
  end

  defp start_segment_uploads(context, duration) do
    0..(context.count - 1)
    |> Enum.reduce_while({:ok, []}, fn index, {:ok, assets} ->
      key = segment_key(context.embed_hash, context.version, index, context.codec)

      case context.storage_adapter.start_presigned_multipart_upload(
             context.bucket,
             key,
             context.region,
             media_type(context.codec),
             max_bytes: 32 * 1024 * 1024
           ) do
        {:ok, session} ->
          asset = %{
            index: index,
            key: key,
            name: "thumbnail_#{index}.#{context.codec}",
            session: session,
            timestamp_seconds: segment_timestamp(index, context.count, duration)
          }

          {:cont, {:ok, assets ++ [asset]}}

        {:error, reason} ->
          abort_segment_uploads(context.storage_adapter, assets)
          {:halt, {:error, reason}}
      end
    end)
  end

  defp upload_segments_with_booster(context, input_url, duration, assets) do
    outputs =
      Enum.map(assets, fn asset ->
        %{"name" => asset.name, "output_upload" => asset.session.payload}
      end)

    options =
      [
        operation: "segments",
        frame_codec: context.codec,
        duration_seconds: duration,
        count: context.count,
        on_chunk: booster_progress_callback(context)
      ]
      |> maybe_add_encoding_booster_referer(input_url)

    case encoding_booster_adapter().encode_many_to_storage(input_url, outputs, options) do
      {:ok, timing} ->
        verify_booster_segments(context, assets, timing)

      {:error, reason} ->
        abort_segment_uploads(context.storage_adapter, assets)
        booster_error(reason)
    end
  end

  defp verify_booster_segments(context, assets, timing) do
    verified =
      Enum.map(assets, fn asset ->
        case context.storage_adapter.object_info(context.bucket, asset.key, context.region) do
          {:ok, %{size_bytes: size_bytes}} when is_integer(size_bytes) and size_bytes > 0 ->
            {:ok,
             %{
               "index" => asset.index,
               "timestamp_seconds" => Float.round(asset.timestamp_seconds, 3),
               "key" => asset.key,
               "uri" => "s3://#{context.bucket}/#{asset.key}",
               "file_size" => size_bytes
             }}

          {:error, reason} ->
            {:error, {:segment_upload_verification_failed, asset.index, reason}}

          _other ->
            {:error, {:segment_upload_verification_failed, asset.index, :empty_object}}
        end
      end)

    case Enum.find(verified, &match?({:error, _reason}, &1)) do
      {:error, reason} ->
        booster_error(reason)

      nil ->
        segments = Enum.map(verified, fn {:ok, segment} -> segment end)
        total_size = Enum.reduce(segments, 0, &(&1["file_size"] + &2))
        report_booster_completed(context, timing, total_size)

        mode_meta =
          %{
            "encoding_booster" => true,
            "encoding_booster_elapsed_ms" => Map.get(timing, :elapsed_ms, 0)
          }
          |> maybe_put_booster_instance(timing)

        {:ok, segments, total_size, "encoding_booster", mode_meta}
    end
  end

  defp abort_segment_uploads(storage_adapter, assets) do
    Enum.each(assets, fn asset ->
      _ = storage_adapter.abort_presigned_multipart_upload(asset.session)
    end)
  end

  defp build_segments(
         "copy",
         run_input,
         source_url,
         dependency_outputs,
         _codec,
         count,
         _progress
       ) do
    with {:ok, source_body} <-
           StepSupport.resolve_source_body(run_input, source_url, dependency_outputs) do
      frames =
        0..(count - 1)
        |> Enum.map(fn index ->
          %{
            index: index,
            timestamp_seconds: index * 1.0,
            body: source_body
          }
        end)

      {:ok, frames, "copy", %{}}
    end
  end

  defp build_segments(
         "ffmpeg",
         run_input,
         source_url,
         dependency_outputs,
         codec,
         count,
         progress
       ) do
    extract_with_ffmpeg(run_input, source_url, dependency_outputs, codec, count, progress)
  end

  defp build_segments(
         "auto",
         run_input,
         source_url,
         dependency_outputs,
         codec,
         count,
         progress
       ) do
    if Map.has_key?(run_input, "source_body") do
      build_segments("copy", run_input, source_url, dependency_outputs, codec, count, progress)
    else
      extract_with_ffmpeg(run_input, source_url, dependency_outputs, codec, count, progress)
    end
  end

  defp extract_with_ffmpeg(
         run_input,
         source_url,
         dependency_outputs,
         codec,
         count,
         progress
       ) do
    StepSupport.with_temp_dir("segments", fn tmp_dir ->
      with {:ok, ffmpeg_bin} <- StepSupport.find_ffmpeg(),
           {:ok, input_ref} <-
             StepSupport.prepare_ffmpeg_input(
               tmp_dir,
               run_input,
               source_url,
               dependency_outputs,
               prefer_video_rendition: true,
               preferred_video_step_id: "video_h264_sd",
               preferred_video_sizes: ["sd"],
               preferred_video_codec: "h264"
             ),
           duration <- probe_duration(input_ref),
           {:ok, frames} <-
             extract_frames(ffmpeg_bin, input_ref, tmp_dir, codec, count, duration, progress) do
        {:ok, frames, "ffmpeg", %{}}
      else
        {:error, reason} -> {:error, reason}
      end
    end)
  end

  defp extract_frames(ffmpeg_bin, input_ref, tmp_dir, codec, count, duration, progress) do
    frames =
      0..(count - 1)
      |> Enum.map(fn index ->
        with {:ok, output_path} <- StepSupport.tmp_file_path(tmp_dir, "thumbnail_#{index}", codec) do
          timestamp_seconds = segment_timestamp(index, count, duration)

          extract_single_frame(
            ffmpeg_bin,
            input_ref,
            output_path,
            codec,
            timestamp_seconds,
            duration,
            count,
            index,
            progress
          )
        end
      end)

    successful_frames =
      frames
      |> Enum.filter(&match?({:ok, _}, &1))
      |> Enum.map(fn {:ok, frame} -> frame end)

    case successful_frames do
      [] ->
        case Enum.find(frames, &match?({:error, _}, &1)) do
          {:error, reason} -> {:error, reason}
          nil -> {:error, :segment_generation_failed}
        end

      _ ->
        {:ok, successful_frames}
    end
  end

  # credo:disable-for-next-line Credo.Check.Refactor.FunctionArity
  defp extract_single_frame(
         ffmpeg_bin,
         input_ref,
         output_path,
         codec,
         timestamp_seconds,
         duration,
         count,
         index,
         progress
       ) do
    fallback_step = max(max(duration, 1.0) / max(count, 1), 0.5)

    timestamp_candidates =
      [
        timestamp_seconds,
        max(timestamp_seconds - fallback_step / 2.0, 0.0),
        max(timestamp_seconds - fallback_step, 0.0),
        0.0
      ]
      |> Enum.map(&Float.round(&1, 3))
      |> Enum.uniq()

    Enum.reduce_while(
      timestamp_candidates,
      {:error, {:segment_read_failed, index, :enoent}},
      fn candidate, _acc ->
        _ = StepSupport.remove_tmp_file(output_path)

        args =
          [
            "-y",
            "-hide_banner",
            "-loglevel",
            "error",
            "-ss",
            format_seconds(candidate),
            "-i",
            input_ref,
            "-frames:v",
            "1"
          ] ++
            codec_args(codec) ++
            ["-vf", RenditionSizing.long_edge_scale_filter(1280), output_path]

        case StepSupport.run_media_cmd(ffmpeg_bin, args, progress: progress) do
          {_, 0} ->
            continue_segment_frame_read(output_path, index, candidate)

          {stderr, status} ->
            {:cont, {:error, {:ffmpeg_exit, status, StepSupport.truncate_binary(stderr, 1000)}}}
        end
      end
    )
  end

  defp segment_timestamp(0, _count, _duration), do: 0.0

  defp segment_timestamp(index, count, duration) do
    safe_duration = max(duration, 1.0)
    Float.round(safe_duration * index / max(count, 1), 3)
  end

  defp put_segments(storage_adapter, bucket, embed_hash, version, codec, frames, region) do
    uploaded =
      Enum.map(frames, fn frame ->
        key = segment_key(embed_hash, version, frame.index, codec)

        case storage_adapter.put_public(bucket, key, frame.body, media_type(codec), region) do
          {:ok, _body} ->
            {:ok,
             %{
               "index" => frame.index,
               "timestamp_seconds" => Float.round(frame.timestamp_seconds, 3),
               "key" => key,
               "uri" => "s3://#{bucket}/#{key}",
               "file_size" => byte_size(frame.body)
             }}

          {:error, reason} ->
            {:error, {:segment_upload_failed, frame.index, reason}}
        end
      end)

    case Enum.find(uploaded, &match?({:error, _}, &1)) do
      {:error, reason} ->
        {:error, reason}

      nil ->
        segments = Enum.map(uploaded, fn {:ok, segment} -> segment end)
        total_size = Enum.reduce(segments, 0, fn segment, acc -> acc + segment["file_size"] end)
        {:ok, segments, total_size}
    end
  end

  defp continue_segment_frame_read(output_path, index, candidate) do
    case StepSupport.read_tmp_file(output_path) do
      {:ok, body} ->
        {:halt,
         {:ok,
          %{
            index: index,
            timestamp_seconds: candidate,
            body: body
          }}}

      {:error, reason} ->
        {:cont, {:error, {:segment_read_failed, index, reason}}}
    end
  end

  defp segment_key(embed_hash, version, index, codec) do
    filename = "thumbnail_#{index}.#{codec}"

    if StepSupport.normalize_version(version) > 0 do
      "#{embed_hash}/v#{StepSupport.normalize_version(version)}/#{filename}"
    else
      "#{embed_hash}/#{filename}"
    end
  end

  defp segments_rendition(codec, size, segments, total_size) do
    first_src = segments |> List.first() |> then(fn segment -> segment && segment["uri"] end)

    %{
      "type" => "segments",
      "codec" => codec,
      "container" => codec,
      "size" => size,
      "progress" => 100.0,
      "src" => first_src,
      "file_size" => total_size
    }
  end

  defp probe_duration(input_ref) do
    case StepSupport.find_ffprobe() do
      {:error, :ffprobe_not_found} ->
        6.0

      {:ok, ffprobe_bin} ->
        args = [
          "-v",
          "error",
          "-show_entries",
          "format=duration",
          "-of",
          "default=noprint_wrappers=1:nokey=1",
          input_ref
        ]

        case StepSupport.run_media_cmd(ffprobe_bin, args) do
          {duration_raw, 0} ->
            duration_raw
            |> String.trim()
            |> parse_float(6.0)
            |> max(0.0)

          _ ->
            6.0
        end
    end
  end

  # FFmpeg 7+ rejects non full-range MJPEG unless strict_std_compliance is relaxed.
  defp codec_args("jpg"), do: ["-c:v", "mjpeg", "-strict", "unofficial", "-q:v", "6"]
  defp codec_args("jpeg"), do: ["-c:v", "mjpeg", "-strict", "unofficial", "-q:v", "6"]
  defp codec_args("webp"), do: ["-c:v", "libwebp", "-quality", "80"]
  defp codec_args(_), do: ["-c:v", "mjpeg", "-strict", "unofficial", "-q:v", "6"]

  defp media_type("jpg"), do: "image/jpeg"
  defp media_type("jpeg"), do: "image/jpeg"
  defp media_type("webp"), do: "image/webp"
  defp media_type(_), do: "application/octet-stream"

  defp format_seconds(seconds) do
    :erlang.float_to_binary(max(seconds, 0.0), decimals: 3)
  end

  defp normalize_positive_integer(value, _default) when is_integer(value) and value > 0,
    do: value

  defp normalize_positive_integer(value, default) when is_binary(value) do
    case Integer.parse(value) do
      {parsed, ""} when parsed > 0 -> parsed
      _ -> default
    end
  end

  defp normalize_positive_integer(_, default), do: default

  defp parse_float(value, default) when is_binary(value) do
    case Float.parse(value) do
      {parsed, _rest} -> parsed
      :error -> default
    end
  end

  defp parse_float(_, default), do: default

  defp media_duration_seconds(dependency_outputs, default) do
    case StepSupport.inspect_duration_ms(dependency_outputs) do
      duration_ms when is_integer(duration_ms) and duration_ms > 0 -> duration_ms / 1_000
      _other -> default
    end
  end

  defp booster_progress_callback(context) do
    fn bytes ->
      StepSupport.report_progress(context.progress_reporter, %{
        "source" => "encoding_booster",
        "executor" => "encoding_booster",
        "status" => "generating",
        "stage" => "generate_segments",
        "step_id" => context.step_id,
        "codec" => context.codec,
        "total_size_bytes" => bytes
      })
    end
  end

  defp report_booster_completed(context, timing, size_bytes) do
    total_ms = StepSupport.inspect_duration_ms(context.dependency_outputs)
    ffmpeg_elapsed_ms = Map.get(timing, :ffmpeg_elapsed_ms) || Map.get(timing, :elapsed_ms)

    StepSupport.report_progress(context.progress_reporter, %{
      "source" => "ffmpeg",
      "executor" => "encoding_booster",
      "status" => "completed",
      "stage" => "generate_segments",
      "step_id" => context.step_id,
      "codec" => context.codec,
      "percent" => 100.0,
      "total_ms" => total_ms,
      "ffmpeg_elapsed_ms" => ffmpeg_elapsed_ms,
      "speed_x" => derived_speed(total_ms, ffmpeg_elapsed_ms),
      "total_size_bytes" => size_bytes,
      "force" => true
    })
  end

  defp derived_speed(total_ms, elapsed_ms)
       when is_integer(total_ms) and is_integer(elapsed_ms) and elapsed_ms > 0,
       do: total_ms / elapsed_ms

  defp derived_speed(_total_ms, _elapsed_ms), do: nil

  defp maybe_add_encoding_booster_referer(options, input_url) do
    if Storage.ffmpeg_storage_url?(input_url) do
      case Storage.ffmpeg_input_referer() do
        referer when is_binary(referer) -> Keyword.put(options, :input_referer, referer)
        _other -> options
      end
    else
      options
    end
  end

  defp encoding_booster_adapter do
    Application.get_env(:mave_core, :encoding_booster_adapter, EncodingBooster)
  end

  defp booster_error(:encoding_booster_busy), do: {:error, :encoding_booster_busy}

  defp booster_error(reason) do
    if EncodingBooster.fallback_enabled?() do
      {:error, {:encoding_booster_fallback_required, encoding_booster_error_code(reason), reason}}
    else
      {:error, reason}
    end
  end

  defp encoding_booster_error_code(reason) do
    reason
    |> inspect(limit: 10, printable_limit: 200)
    |> String.replace(~r/[^a-zA-Z0-9]+/, "_")
    |> String.trim("_")
    |> String.downcase()
    |> String.slice(0, 80)
    |> case do
      "" -> "error"
      code -> code
    end
  end

  defp maybe_put_booster_instance(metadata, %{instance_id: instance_id})
       when is_binary(instance_id),
       do: Map.put(metadata, "encoding_booster_instances", [instance_id])

  defp maybe_put_booster_instance(metadata, _timing), do: metadata

  defp maybe_put_fallback(metadata, nil), do: metadata

  defp maybe_put_fallback(metadata, code),
    do: Map.put(metadata, "encoding_booster_fallback", code)

  defp unavailable_output(step_id, codec, size, reason) do
    %{
      "status" => "unavailable",
      "step_type" => "media.generate_segments",
      "mode" => "failed",
      "step_id" => step_id,
      "codec" => codec,
      "size" => size,
      "error" => inspect(reason)
    }
  end

  defp skipped_output(step_id, codec, size, reason) do
    %{
      "status" => "skipped",
      "step_type" => "media.generate_segments",
      "mode" => "skipped",
      "step_id" => step_id,
      "codec" => codec,
      "container" => codec,
      "size" => size,
      "reason" => reason
    }
  end
end
