defmodule MaveCore.Flow.Steps.MediaExtractFrameStep do
  @moduledoc """
  Produces an image frame artifact (poster/thumbnail/placeholder/custom role).

  Modes:
  - `auto` (default): FFmpeg for normal sources; copy-mode only for inline `source_body`
  - `copy`: compatibility mode for inline `source_body`
  - `ffmpeg`: always use FFmpeg frame extraction
  """
  @behaviour MaveCore.Flow.Step

  alias MaveCore.EncodingBooster
  alias MaveCore.Flow.Steps.Support, as: StepSupport
  alias MaveCore.Media.RenditionSizing
  alias MaveCore.Media.Signature
  alias MaveCore.Media.Storage

  @supported_modes ~w(auto copy ffmpeg)
  @poster_scale_filter RenditionSizing.normalize_sar_filter()
  @even_poster_scale_filter "scale=trunc(iw*sar/2)*2:trunc(ih/2)*2,setsar=1"

  @impl true
  def run(step_definition, context) do
    run_input = Map.get(context, :run_input, %{})
    dependency_outputs = Map.get(context, :dependency_outputs, %{})
    source = Map.get(dependency_outputs, "source", %{})
    params = Map.get(step_definition, "params", %{})
    step_id = Map.get(step_definition, "id", "extract_frame")

    source_url =
      Map.get(source, "source_url") || Map.get(run_input, "input_url") ||
        Map.get(run_input, "source_url")

    space_hash = Map.get(source, "space_hash") || Map.get(run_input, "space_hash")
    embed_hash = Map.get(source, "embed_hash") || Map.get(run_input, "embed_hash")
    version = Map.get(source, "version") || Map.get(run_input, "version", 0)
    region = Map.get(run_input, "region")
    role = StepSupport.normalize_param_downcase(Map.get(params, "role"), infer_role(step_id))
    codec = StepSupport.normalize_param_downcase(Map.get(params, "codec"), "jpg")
    at_seconds = frame_at_seconds(params, dependency_outputs)
    mode = StepSupport.normalize_mode(run_input, "media_extract_frame_mode", @supported_modes)
    strict? = StepSupport.strict_enabled?(params, run_input, "media_extract_frame_strict")
    storage_adapter = Application.get_env(:mave_core, :flow_storage_adapter, Storage)
    bucket = Storage.bucket_for_space(space_hash, region)

    booster_context = %{
      dispatch: Map.get(context, :encoding_booster_dispatch),
      fallback_code: Map.get(context, :encoding_booster_fallback_code),
      progress_reporter: Map.get(context, :progress_reporter),
      storage_adapter: storage_adapter,
      bucket: bucket,
      region: region,
      step_id: step_id,
      source_step_id: Map.get(params, "source_step_id")
    }

    progress =
      StepSupport.ffmpeg_progress(Map.get(context, :progress_reporter), %{
        stage: "extract_frame",
        step_id: step_id,
        codec: codec,
        size: role,
        container: codec
      })

    if reason = StepSupport.frame_skip_reason(params, dependency_outputs) do
      {:ok, skipped_output(step_id, role, codec, reason), []}
    else
      extract_frame(
        run_input,
        dependency_outputs,
        source_url,
        space_hash,
        embed_hash,
        version,
        region,
        role,
        codec,
        at_seconds,
        mode,
        strict?,
        storage_adapter,
        bucket,
        step_id,
        progress,
        booster_context
      )
    end
  end

  # credo:disable-for-next-line Credo.Check.Refactor.FunctionArity
  defp extract_frame(
         run_input,
         dependency_outputs,
         source_url,
         space_hash,
         embed_hash,
         version,
         region,
         role,
         codec,
         at_seconds,
         mode,
         strict?,
         storage_adapter,
         bucket,
         step_id,
         progress,
         booster_context
       ) do
    with {:ok, space_hash} <- StepSupport.require_binary(space_hash, :space_hash),
         {:ok, embed_hash} <- StepSupport.require_binary(embed_hash, :embed_hash),
         {:ok, source_url} <- StepSupport.require_binary(source_url, :source_url),
         {:ok, key} <- build_key(embed_hash, version, role, codec),
         frame_spec = %{role: role, codec: codec, at_seconds: at_seconds},
         {:ok, frame_body, actual_mode, mode_meta} <-
           build_frame_body(
             mode,
             run_input,
             source_url,
             dependency_outputs,
             frame_spec,
             progress,
             Map.merge(booster_context, %{key: key, dependency_outputs: dependency_outputs})
           ),
         {:ok, file_size, uri} <-
           put_frame(storage_adapter, bucket, key, frame_body, codec, region) do
      rendition = frame_rendition(role, codec, key, uri, file_size)

      output =
        %{
          "status" => "ok",
          "step_type" => "media.extract_frame",
          "mode" => actual_mode,
          "step_id" => step_id,
          "role" => role,
          "codec" => codec,
          "bucket" => bucket,
          "key" => key,
          "uri" => uri,
          "src" => uri,
          "file_size" => file_size,
          "rendition" => rendition,
          "renditions" => [rendition]
        }
        |> maybe_add_poster_src(role, uri)
        |> Map.merge(mode_meta)

      artifacts = [
        %{
          name: "#{role}_frame",
          uri: uri,
          media_type: media_type(codec),
          size_bytes: file_size,
          metadata: %{
            "type" => "image",
            "role" => role,
            "codec" => codec,
            "space_hash" => space_hash,
            "embed_hash" => embed_hash,
            "version" => StepSupport.normalize_version(version)
          }
        }
      ]

      {:ok, output, artifacts}
    else
      {:error, {:encoding_booster_fallback_required, _code, _reason} = reason} ->
        {:error, reason}

      {:error, :encoding_booster_busy} ->
        {:error, {:media_extract_frame_failed, :encoding_booster_busy}}

      {:error, reason} when strict? ->
        {:error, {:media_extract_frame_failed, reason}}

      {:error, reason} ->
        {:ok, unavailable_output(step_id, role, codec, reason), []}
    end
  end

  defp build_frame_body(
         _mode,
         run_input,
         source_url,
         dependency_outputs,
         frame_spec,
         _progress,
         %{dispatch: :direct} = booster_context
       ) do
    extract_with_booster(
      run_input,
      source_url,
      dependency_outputs,
      frame_spec.role,
      frame_spec.codec,
      frame_spec.at_seconds,
      Map.get(booster_context, :source_step_id),
      booster_context
    )
  end

  defp build_frame_body(
         "copy",
         run_input,
         source_url,
         dependency_outputs,
         _frame_spec,
         _progress,
         _booster_context
       ) do
    with {:ok, source_body} <-
           StepSupport.resolve_source_body(run_input, source_url, dependency_outputs) do
      {:ok, source_body, "copy", %{}}
    end
  end

  defp build_frame_body(
         "ffmpeg",
         run_input,
         source_url,
         dependency_outputs,
         frame_spec,
         progress,
         booster_context
       ) do
    extract_with_ffmpeg(
      run_input,
      source_url,
      dependency_outputs,
      frame_spec.role,
      frame_spec.codec,
      frame_spec.at_seconds,
      Map.get(booster_context, :source_step_id),
      progress
    )
  end

  defp build_frame_body(
         "auto",
         run_input,
         source_url,
         dependency_outputs,
         frame_spec,
         progress,
         booster_context
       ) do
    if Map.has_key?(run_input, "source_body") do
      build_frame_body(
        "copy",
        run_input,
        source_url,
        dependency_outputs,
        frame_spec,
        progress,
        booster_context
      )
    else
      extract_with_ffmpeg(
        run_input,
        source_url,
        dependency_outputs,
        frame_spec.role,
        frame_spec.codec,
        frame_spec.at_seconds,
        Map.get(booster_context, :source_step_id),
        progress
      )
    end
  end

  defp extract_with_booster(
         run_input,
         source_url,
         dependency_outputs,
         role,
         codec,
         at_seconds,
         source_step_id,
         booster_context
       ) do
    with {:ok, input_url} <-
           StepSupport.encoding_booster_input_url(
             run_input,
             source_url,
             dependency_outputs,
             frame_source_opts(role, source_step_id, dependency_outputs)
           ),
         {:ok, session} <-
           booster_context.storage_adapter.start_presigned_multipart_upload(
             booster_context.bucket,
             booster_context.key,
             booster_context.region,
             media_type(codec),
             max_bytes: 64 * 1024 * 1024
           ) do
      options =
        [
          operation: "frame",
          frame_role: role,
          frame_codec: codec,
          start_seconds: at_seconds,
          on_chunk: booster_progress_callback(booster_context, role, codec)
        ]
        |> maybe_add_encoding_booster_referer(input_url)

      case encoding_booster_adapter().encode_to_storage(input_url, session.payload, options) do
        {:ok, timing} ->
          verify_booster_frame(booster_context, timing, role, codec)

        {:error, reason} ->
          _ = booster_context.storage_adapter.abort_presigned_multipart_upload(session)
          booster_error(reason)
      end
    else
      {:error, reason} -> booster_error(reason)
    end
  end

  defp verify_booster_frame(booster_context, timing, role, codec) do
    case booster_context.storage_adapter.object_info(
           booster_context.bucket,
           booster_context.key,
           booster_context.region
         ) do
      {:ok, %{size_bytes: size_bytes}} when is_integer(size_bytes) and size_bytes > 0 ->
        report_booster_completed(booster_context, timing, role, codec, size_bytes)

        metadata =
          %{
            "encoding_booster" => true,
            "encoding_booster_elapsed_ms" => Map.get(timing, :elapsed_ms, 0)
          }
          |> maybe_put_booster_instance(timing)

        {:ok, %{stored: true, size_bytes: size_bytes, uri: booster_frame_uri(booster_context)},
         "encoding_booster", metadata}

      {:error, reason} ->
        booster_error({:frame_upload_verification_failed, reason})

      _other ->
        booster_error({:frame_upload_verification_failed, :empty_object})
    end
  end

  defp booster_frame_uri(booster_context) do
    "s3://#{booster_context.bucket}/#{booster_context.key}"
  end

  defp booster_error(:encoding_booster_busy), do: {:error, :encoding_booster_busy}

  defp booster_error(reason) do
    if EncodingBooster.fallback_enabled?() do
      {:error, {:encoding_booster_fallback_required, encoding_booster_error_code(reason), reason}}
    else
      {:error, reason}
    end
  end

  defp booster_progress_callback(booster_context, role, codec) do
    fn bytes ->
      StepSupport.report_progress(booster_context.progress_reporter, %{
        "source" => "encoding_booster",
        "executor" => "encoding_booster",
        "status" => "extracting",
        "stage" => "extract_frame",
        "step_id" => booster_context.step_id,
        "codec" => codec,
        "size" => role,
        "container" => codec,
        "total_size_bytes" => bytes
      })
    end
  end

  defp report_booster_completed(booster_context, timing, role, codec, size_bytes) do
    StepSupport.report_progress(booster_context.progress_reporter, %{
      "source" => "ffmpeg",
      "executor" => "encoding_booster",
      "status" => "completed",
      "stage" => "extract_frame",
      "step_id" => booster_context.step_id,
      "codec" => codec,
      "size" => role,
      "container" => codec,
      "percent" => 100.0,
      "ffmpeg_elapsed_ms" => Map.get(timing, :ffmpeg_elapsed_ms) || Map.get(timing, :elapsed_ms),
      "total_size_bytes" => size_bytes,
      "force" => true
    })
  end

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

  defp maybe_put_booster_instance(metadata, %{instance_id: instance_id})
       when is_binary(instance_id),
       do: Map.put(metadata, "encoding_booster_instances", [instance_id])

  defp maybe_put_booster_instance(metadata, _timing), do: metadata

  defp encoding_booster_error_code(:encoding_booster_busy), do: "busy"
  defp encoding_booster_error_code({:encoding_booster_http_status, status}), do: "http_#{status}"
  defp encoding_booster_error_code(_reason), do: "request_failed"

  defp extract_with_ffmpeg(
         run_input,
         source_url,
         dependency_outputs,
         role,
         codec,
         at_seconds,
         source_step_id,
         progress
       ) do
    StepSupport.with_temp_dir("extract_frame", fn tmp_dir ->
      with {:ok, output_path} <- build_output_path(tmp_dir, codec),
           {:ok, ffmpeg_output, fallback?} <-
             StepSupport.run_ffmpeg_with_storage_fallback(
               tmp_dir,
               run_input,
               source_url,
               dependency_outputs,
               &build_ffmpeg_args(&1, output_path, role, codec, at_seconds),
               [progress: progress] ++ frame_source_opts(role, source_step_id, dependency_outputs)
             ),
           {:ok, frame_body} <- StepSupport.read_tmp_file(output_path) do
        {:ok, frame_body, "ffmpeg",
         %{"ffmpeg_output" => StepSupport.truncate_binary(ffmpeg_output, 500)}
         |> Map.merge(StepSupport.ffmpeg_fallback_metadata(fallback?))}
      else
        {:error, {ffmpeg_output, status}} when is_binary(ffmpeg_output) and is_integer(status) ->
          {:error, {:ffmpeg_exit, status, StepSupport.truncate_binary(ffmpeg_output, 1000)}}

        {:error, reason} ->
          {:error, reason}
      end
    end)
  end

  defp frame_source_opts(_role, source_step_id, dependency_outputs)
       when is_binary(source_step_id) and source_step_id != "" do
    content_type =
      case get_in(dependency_outputs, [source_step_id, "step_type"]) do
        "media.transcode_waveform" -> "video/mp4"
        _ -> "image/jpeg"
      end

    [
      preferred_storage_step_id: source_step_id,
      preferred_storage_content_type: content_type
    ]
  end

  defp frame_source_opts(role, _source_step_id, _dependency_outputs),
    do: preferred_video_source_opts(role)

  defp preferred_video_source_opts("poster") do
    [
      prefer_video_rendition: true,
      preferred_video_step_id: "video_h264_ladder",
      preferred_video_sizes: ["fhd", "hd", "sd"],
      preferred_video_codec: "h264"
    ]
  end

  defp preferred_video_source_opts(_role) do
    [
      prefer_video_rendition: true,
      preferred_video_step_id: "video_h264_ladder",
      preferred_video_sizes: ["sd"],
      preferred_video_codec: "h264"
    ]
  end

  defp build_output_path(tmp_dir, codec) do
    with {:ok, codec} <- StepSupport.require_binary(codec, :codec) do
      StepSupport.tmp_file_path(tmp_dir, "frame", codec)
    end
  end

  defp thumbnail_input_args("custom_thumbnail"),
    do: ["-format_whitelist", Signature.image_formats()]

  defp thumbnail_input_args(_role), do: []

  defp build_ffmpeg_args(input_ref, output_path, role, codec, at_seconds) do
    with {:ok, codec_name} <- codec_name(codec) do
      seek_seconds =
        at_seconds
        |> max(0.0)
        |> :erlang.float_to_binary(decimals: 3)

      input_args =
        ["-hide_banner", "-loglevel", "error", "-y"] ++
          thumbnail_input_args(role) ++
          if(at_seconds > 0, do: ["-ss", seek_seconds], else: []) ++ ["-i", input_ref]

      case role do
        "poster" ->
          {:ok,
           input_args ++
             [
               "-map_metadata",
               "-1",
               "-c:v",
               codec_name,
               "-vf",
               poster_scale_filter(codec),
               "-frames:v",
               "1"
             ] ++ poster_quality_args(codec) ++ [output_path]}

        role when role in ["thumbnail", "custom_thumbnail"] ->
          {:ok,
           input_args ++
             [
               "-map_metadata",
               "-1",
               "-c:v",
               codec_name,
               "-frames:v",
               "1",
               "-vf",
               RenditionSizing.long_edge_scale_filter(1280)
             ] ++ codec_fallback_args(codec) ++ [output_path]}

        "placeholder" ->
          {:ok,
           [
             "-hide_banner",
             "-loglevel",
             "error",
             "-y",
             "-i",
             input_ref,
             "-i",
             play_button_image_ref(),
             "-map_metadata",
             "-1",
             "-filter_complex",
             "[1:v]scale=iw*0.15:-1[logo];[0:v][logo]overlay=(main_w-overlay_w)/2:(main_h-overlay_h)/2",
             "-frames:v",
             "1",
             "-q:v",
             "2",
             output_path
           ]}

        _ ->
          {:ok,
           [
             "-y",
             "-hide_banner",
             "-loglevel",
             "error",
             "-ss",
             seek_seconds,
             "-i",
             input_ref,
             "-frames:v",
             "1",
             "-c:v",
             codec_name
           ] ++ codec_fallback_args(codec) ++ [output_path]}
      end
    end
  end

  defp poster_quality_args("av1"), do: ["-crf", "55"]
  defp poster_quality_args("avif"), do: ["-crf", "55", "-svtav1-params", "avif=1"]
  defp poster_quality_args("webp"), do: ["-quality", "10"]
  defp poster_quality_args(_codec), do: ["-q:v", "6"]

  defp poster_scale_filter(codec) when codec in ["av1", "avif"], do: @even_poster_scale_filter
  defp poster_scale_filter(_codec), do: @poster_scale_filter

  defp codec_name("jpg"), do: {:ok, "mjpeg"}
  defp codec_name("jpeg"), do: {:ok, "mjpeg"}
  defp codec_name("png"), do: {:ok, "png"}
  defp codec_name("webp"), do: {:ok, "libwebp"}
  defp codec_name("av1"), do: {:ok, "libsvtav1"}
  defp codec_name("avif"), do: {:ok, "libsvtav1"}
  defp codec_name(other), do: {:error, {:unsupported_codec, other}}

  defp codec_fallback_args("jpg"), do: ["-q:v", "6"]
  defp codec_fallback_args("jpeg"), do: ["-q:v", "6"]
  defp codec_fallback_args("webp"), do: ["-quality", "10"]
  defp codec_fallback_args("av1"), do: ["-crf", "55"]
  defp codec_fallback_args("avif"), do: ["-crf", "55", "-svtav1-params", "avif=1"]
  defp codec_fallback_args(_), do: []

  defp build_key(embed_hash, version, role, codec) do
    with {:ok, embed_hash} <- StepSupport.require_binary(embed_hash, :embed_hash),
         {:ok, role} <- StepSupport.require_binary(role, :role),
         {:ok, codec} <- StepSupport.require_binary(codec, :codec) do
      filename = "#{role}.#{codec}"

      key =
        if StepSupport.normalize_version(version) > 0 do
          "#{embed_hash}/v#{StepSupport.normalize_version(version)}/#{filename}"
        else
          "#{embed_hash}/#{filename}"
        end

      {:ok, key}
    end
  end

  defp put_frame(
         _storage_adapter,
         _bucket,
         _key,
         %{stored: true, size_bytes: size_bytes, uri: uri},
         _codec,
         _region
       ) do
    {:ok, size_bytes, uri}
  end

  defp put_frame(storage_adapter, bucket, key, body, codec, region) do
    case storage_adapter.put_public(bucket, key, body, media_type(codec), region) do
      {:ok, _body} -> {:ok, byte_size(body), "s3://#{bucket}/#{key}"}
      {:error, reason} -> {:error, {:frame_upload_failed, reason}}
    end
  end

  defp frame_rendition(role, codec, key, uri, file_size) do
    %{
      "type" => "image",
      "role" => role,
      "codec" => codec,
      "container" => codec,
      "progress" => 100.0,
      "rendition_key" => key,
      "src" => uri,
      "file_size" => file_size
    }
  end

  defp maybe_add_poster_src(output, "poster", uri), do: Map.put(output, "poster_image_src", uri)
  defp maybe_add_poster_src(output, _role, _uri), do: output

  defp unavailable_output(step_id, role, codec, reason) do
    %{
      "status" => "unavailable",
      "step_type" => "media.extract_frame",
      "mode" => "failed",
      "step_id" => step_id,
      "role" => role,
      "codec" => codec,
      "error" => inspect(reason)
    }
  end

  defp skipped_output(step_id, role, codec, reason) do
    %{
      "status" => "skipped",
      "step_type" => "media.extract_frame",
      "mode" => "skipped",
      "step_id" => step_id,
      "role" => role,
      "codec" => codec,
      "reason" => reason
    }
  end

  defp media_type("jpg"), do: "image/jpeg"
  defp media_type("jpeg"), do: "image/jpeg"
  defp media_type("png"), do: "image/png"
  defp media_type("webp"), do: "image/webp"
  defp media_type("avif"), do: "image/avif"
  defp media_type(_), do: "application/octet-stream"

  defp play_button_image_ref do
    case :code.priv_dir(:mave_core) do
      priv_dir when is_list(priv_dir) ->
        path = Path.join([List.to_string(priv_dir), "static", "images", "play.png"])
        if File.regular?(path), do: path, else: raise("bundled play button image is missing")

      _other ->
        raise "could not resolve the bundled play button image"
    end
  end

  defp infer_role(step_id) when is_binary(step_id) do
    cond do
      String.contains?(step_id, "poster") -> "poster"
      String.contains?(step_id, "thumbnail") -> "thumbnail"
      String.contains?(step_id, "placeholder") -> "placeholder"
      true -> "frame"
    end
  end

  defp infer_role(_), do: "frame"

  defp frame_at_seconds(params, dependency_outputs) do
    default_seconds =
      case {normalize_float(Map.get(params, "at_fraction"), 0.0),
            StepSupport.inspect_duration_ms(dependency_outputs)} do
        {fraction, duration_ms}
        when fraction > 0 and fraction < 1 and is_integer(duration_ms) ->
          fraction * duration_ms / 1_000

        _ ->
          0.0
      end

    normalize_float(Map.get(params, "at_seconds"), default_seconds)
  end

  defp normalize_float(nil, default), do: default
  defp normalize_float(value, _default) when is_float(value), do: value
  defp normalize_float(value, _default) when is_integer(value), do: value * 1.0

  defp normalize_float(value, default) when is_binary(value) do
    case Float.parse(value) do
      {parsed, ""} -> parsed
      _ -> default
    end
  end

  defp normalize_float(_value, default), do: default
end
