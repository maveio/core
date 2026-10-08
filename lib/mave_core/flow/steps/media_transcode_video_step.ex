defmodule MaveCore.Flow.Steps.MediaTranscodeVideoStep do
  @moduledoc """
  Produces a video rendition artifact for a configured codec/size step.

  Default behavior:
  - `auto`: uses FFmpeg for normal sources; copy-mode only for inline `source_body`.
  - `copy`: compatibility mode for inline `source_body`.
  - `ffmpeg`: always attempts FFmpeg transcode.
  """
  @behaviour MaveCore.Flow.Step

  require Logger

  alias MaveCore.EncodingBooster
  alias MaveCore.Flow.Steps.Support, as: StepSupport
  alias MaveCore.GpuEncodingBooster
  alias MaveCore.Media.{ProductionEncodingProfile, RenditionSizing, Storage}

  @supported_modes ~w(auto copy ffmpeg)
  @booster_output_capacity_multiplier 2.0
  # GOP-2 CRF output can far exceed its nominal bitrate. Start with 128 MiB at
  # SD and scale the floor with output pixels so dense HD/FHD clips cannot
  # exhaust their presigned multipart destinations.
  @dense_keyframe_sd_capacity_bytes 128 * 1024 * 1024
  @sd_long_edge 640
  @source_copy_long_edges %{
    "source" => :infinity,
    "original" => :infinity
  }

  @impl true
  def run(step_definition, context) do
    context = transcode_context(step_definition, context)

    case skip_reason(context) do
      nil -> transcode_video_from_context(context)
      reason -> skipped_transcode_result(context, reason)
    end
  end

  defp transcode_context(step_definition, context) do
    run_input = Map.get(context, :run_input, %{})
    dependency_outputs = Map.get(context, :dependency_outputs, %{})
    source = Map.get(dependency_outputs, "source", %{})
    params = Map.get(step_definition, "params", %{})

    source_url =
      Map.get(source, "source_url") || Map.get(run_input, "input_url") ||
        Map.get(run_input, "source_url")

    space_hash = Map.get(source, "space_hash") || Map.get(run_input, "space_hash")
    embed_hash = Map.get(source, "embed_hash") || Map.get(run_input, "embed_hash")
    version = Map.get(source, "version") || Map.get(run_input, "version", 0)
    region = Map.get(run_input, "region")
    codec = normalize_param(Map.get(params, "codec"), "h264")
    size = normalize_param(Map.get(params, "size"), "sd")
    container = normalize_param(Map.get(params, "container"), "mp4")
    mode = StepSupport.normalize_mode(run_input, "media_transcode_video_mode", @supported_modes)

    keyframe_interval =
      normalize_integer(Map.get(params, "keyframe_interval")) ||
        normalize_integer(Map.get(run_input, "keyframe_interval")) || 250

    strict? = StepSupport.strict_enabled?(params, run_input, "media_transcode_video_strict")
    storage_adapter = Application.get_env(:mave_core, :flow_storage_adapter, Storage)
    bucket = Storage.bucket_for_space(space_hash, region)

    %{
      run_input: run_input,
      dependency_outputs: dependency_outputs,
      source_url: source_url,
      space_hash: space_hash,
      embed_hash: embed_hash,
      version: version,
      region: region,
      codec: codec,
      size: size,
      container: container,
      keyframe_interval: keyframe_interval,
      strict?: strict?,
      storage_adapter: storage_adapter,
      bucket: bucket,
      step_id: Map.get(step_definition, "id", "video_transcode"),
      mode: mode,
      progress_reporter: Map.get(context, :progress_reporter),
      gpu_encoding_booster_dispatch: Map.get(context, :gpu_encoding_booster_dispatch),
      gpu_encoding_booster_fallback_code: Map.get(context, :gpu_encoding_booster_fallback_code),
      encoding_booster_dispatch: Map.get(context, :encoding_booster_dispatch),
      encoding_booster_fallback_code: Map.get(context, :encoding_booster_fallback_code),
      params: params
    }
  end

  defp skip_reason(context) do
    cond do
      StepSupport.inspect_reports_no_video?(context.dependency_outputs) ->
        "no video stream"

      source_resolution_below_variant?(context.params, context.dependency_outputs, context.size) ->
        "source_resolution_below_variant"

      true ->
        nil
    end
  end

  defp transcode_video_from_context(context) do
    transcode_video(context)
  end

  defp skipped_transcode_result(context, reason) do
    {:ok, skipped_output(context.step_id, context.codec, context.size, context.container, reason),
     []}
  end

  defp transcode_video(context) do
    with {:ok, space_hash} <- StepSupport.require_binary(context.space_hash, :space_hash),
         {:ok, embed_hash} <- StepSupport.require_binary(context.embed_hash, :embed_hash),
         {:ok, source_url} <- StepSupport.require_binary(context.source_url, :source_url),
         {:ok, key} <-
           build_key(
             embed_hash,
             context.version,
             context.codec,
             context.size,
             context.container,
             context.keyframe_interval
           ),
         rendition_context = %{context | source_url: source_url} |> Map.put(:key, key),
         {:ok, rendition, actual_mode, mode_meta} <-
           put_or_copy_rendition(rendition_context) do
      file_size = rendition.file_size
      artifact_name = artifact_name(context.codec, context.size)
      duration = inspect_duration(context.dependency_outputs)

      rendition_type = rendition_type(context.codec, context.keyframe_interval)

      output =
        %{
          "status" => "ok",
          "step_type" => "media.transcode_video",
          "mode" => actual_mode,
          "step_id" => context.step_id,
          "codec" => context.codec,
          "size" => context.size,
          "container" => context.container,
          "resolution" => output_resolution(context.size, context.dependency_outputs),
          "bucket" => context.bucket,
          "key" => key,
          "uri" => rendition.uri,
          "file_size" => file_size,
          "duration" => duration,
          "duration_ms" => duration_ms(duration),
          "rendition" => %{
            "type" => rendition_type,
            "size" => context.size,
            "codec" => context.codec,
            "container" => context.container,
            "progress" => 100.0,
            "rendition_key" => key,
            "src" => rendition.uri,
            "file_size" => file_size
          },
          "renditions" => [
            %{
              "type" => rendition_type,
              "size" => context.size,
              "codec" => context.codec,
              "container" => context.container,
              "progress" => 100.0,
              "rendition_key" => key,
              "src" => rendition.uri,
              "file_size" => file_size
            }
          ]
        }
        |> Map.merge(mode_meta)

      artifacts = [
        %{
          name: artifact_name,
          uri: rendition.uri,
          media_type: media_type(context.container),
          size_bytes: file_size,
          metadata: %{
            "type" => "video",
            "codec" => context.codec,
            "size" => context.size,
            "container" => context.container,
            "space_hash" => space_hash,
            "embed_hash" => embed_hash,
            "version" => StepSupport.normalize_version(context.version)
          }
        }
      ]

      {:ok, output, artifacts}
    else
      {:error, {:gpu_encoding_booster_fallback_required, _code, _reason} = reason} ->
        {:error, reason}

      {:error, {:encoding_booster_fallback_required, _code, _reason} = reason} ->
        {:error, reason}

      {:error, :encoding_booster_busy} ->
        {:error, {:media_transcode_video_failed, :encoding_booster_busy}}

      {:error, reason} when context.strict? ->
        {:error, {:media_transcode_video_failed, reason}}

      {:error, reason} ->
        {:ok,
         unavailable_output(
           context.step_id,
           context.codec,
           context.size,
           context.container,
           reason
         ), []}
    end
  end

  defp put_or_copy_rendition(%{mode: mode} = context) do
    case maybe_copy_source_rendition(context) do
      {:ok, rendition, mode_meta} ->
        {:ok, rendition, "source_copy", mode_meta}

      :skip ->
        put_transcoded_rendition(mode, context)
    end
  end

  defp put_transcoded_rendition(_mode, %{gpu_encoding_booster_dispatch: :direct} = context) do
    run_booster_or_delegate(context, :gpu)
  end

  defp put_transcoded_rendition(_mode, %{encoding_booster_dispatch: :direct} = context) do
    run_booster_or_delegate(context, :cpu)
  end

  defp put_transcoded_rendition(mode, context) do
    with {:ok, rendition_body, actual_mode, mode_meta} <- build_rendition_body(mode, context),
         {:ok, uri} <-
           put_rendition(
             context.storage_adapter,
             context.bucket,
             context.key,
             rendition_body,
             context.container,
             context.region
           ) do
      fallback_meta =
        mode_meta
        |> maybe_put_fallback(
          "gpu_encoding_booster_fallback",
          context.gpu_encoding_booster_fallback_code
        )
        |> maybe_put_fallback("encoding_booster_fallback", context.encoding_booster_fallback_code)

      {:ok, %{file_size: byte_size(rendition_body), uri: uri}, actual_mode, fallback_meta}
    end
  end

  defp maybe_copy_source_rendition(
         %{
           mode: "auto",
           codec: "h264",
           container: "mp4",
           keyframe_interval: keyframe_interval
         } = context
       )
       when keyframe_interval != 2 do
    with {:ok, inspect_output} <- source_copy_inspect_output(context),
         :ok <- ensure_h264_mp4_source(inspect_output, context.run_input),
         :ok <- ensure_source_fits_size(inspect_output, context.size),
         {:ok, source_bucket, source_key, source_region} <-
           uploaded_original_reference(context.run_input, context.dependency_outputs),
         :ok <- ensure_same_storage_profile(source_region, context.region),
         {:ok, file_size} <-
           source_object_size(
             context.storage_adapter,
             source_bucket,
             source_key,
             source_region,
             inspect_output
           ),
         :ok <-
           copy_source_public(
             context.storage_adapter,
             context.bucket,
             context.key,
             source_bucket,
             source_key,
             context.region
           ) do
      {:ok, %{file_size: file_size, uri: "s3://#{context.bucket}/#{context.key}"},
       %{
         "source_copy" => true,
         "source_copy_key" => source_key
       }}
    else
      _ -> :skip
    end
  end

  defp maybe_copy_source_rendition(_context), do: :skip

  defp build_rendition_body("copy", context) do
    with {:ok, source_body} <-
           StepSupport.resolve_source_body(
             context.run_input,
             context.source_url,
             context.dependency_outputs
           ) do
      {:ok, source_body, "copy", %{}}
    end
  end

  defp build_rendition_body("ffmpeg", context) do
    transcode_with_ffmpeg(context)
  end

  defp build_rendition_body("auto", context) do
    if Map.has_key?(context.run_input, "source_body") do
      build_rendition_body("copy", context)
    else
      transcode_with_ffmpeg(context)
    end
  end

  defp run_booster_or_delegate(context, profile) do
    case transcode_with_booster(context, profile) do
      {:ok, _rendition, _actual_mode, _metadata} = success ->
        success

      {:error, reason} ->
        booster_fallback_error(context, profile, reason)
    end
  end

  defp booster_fallback_error(context, :gpu, reason) do
    if GpuEncodingBooster.fallback_enabled?() do
      error_code = encoding_booster_error_code(reason)

      Logger.warning(
        "GPU encoding booster failed for #{context.step_id}; delegating to CPU booster: #{error_code}"
      )

      {:error, {:gpu_encoding_booster_fallback_required, error_code, reason}}
    else
      {:error, reason}
    end
  end

  defp booster_fallback_error(_context, :cpu, :encoding_booster_busy),
    do: {:error, :encoding_booster_busy}

  defp booster_fallback_error(context, :cpu, reason) do
    if EncodingBooster.fallback_enabled?() do
      error_code = encoding_booster_error_code(reason)

      Logger.warning(
        "Encoding booster failed for #{context.step_id}; delegating to FLAME FFmpeg: #{error_code}"
      )

      {:error, {:encoding_booster_fallback_required, error_code, reason}}
    else
      {:error, reason}
    end
  end

  defp transcode_with_booster(context, :cpu) do
    with {:ok, input_url} <-
           StepSupport.encoding_booster_input_url(
             context.run_input,
             context.source_url,
             context.dependency_outputs,
             encoding_booster_input_opts(context)
           ),
         {:ok, encoding_profile} <- production_encoding_profile(context),
         options <-
           encoding_booster_options(input_url, encoding_profile)
           |> Keyword.put(:on_chunk, encoding_booster_upload_progress(context)),
         {:ok, session} <-
           context.storage_adapter.start_presigned_multipart_upload(
             context.bucket,
             context.key,
             context.region,
             media_type(context.container),
             max_bytes:
               booster_output_capacity_bytes(
                 context,
                 encoding_profile.capacity_video_bitrate
               )
           ) do
      upload_booster_rendition(context, input_url, options, session)
    end
  end

  defp transcode_with_booster(context, profile) do
    StepSupport.with_temp_dir("transcode_video_booster", fn tmp_dir ->
      do_transcode_with_booster(context, profile, tmp_dir)
    end)
  end

  defp upload_booster_rendition(context, input_url, options, session) do
    case booster_adapter(:cpu).encode_to_storage(input_url, session.payload, options) do
      {:ok, timing} ->
        verify_booster_rendition(context, timing)

      {:error, reason} ->
        _ = context.storage_adapter.abort_presigned_multipart_upload(session)
        {:error, reason}
    end
  end

  defp verify_booster_rendition(context, timing) do
    case context.storage_adapter.object_info(context.bucket, context.key, context.region) do
      {:ok, %{size_bytes: size_bytes}} when is_integer(size_bytes) and size_bytes > 0 ->
        report_encoding_booster_progress(context, timing, "encoding_booster")

        metadata =
          %{
            "encoding_booster" => true,
            "encoding_booster_elapsed_ms" => Map.get(timing, :elapsed_ms, 0),
            "encoding_booster_storage_direct" => true,
            "encoding_profile" => ProductionEncodingProfile.name()
          }
          |> maybe_put_booster_instance("encoding_booster", timing)

        {:ok, %{file_size: size_bytes, uri: "s3://#{context.bucket}/#{context.key}"},
         "encoding_booster", metadata}

      {:error, reason} ->
        {:error, {:rendition_upload_verification_failed, reason}}

      _other ->
        {:error, {:rendition_upload_verification_failed, :empty_object}}
    end
  end

  defp do_transcode_with_booster(context, profile, tmp_dir) do
    with {:ok, input_url} <-
           StepSupport.encoding_booster_input_url(
             context.run_input,
             context.source_url,
             context.dependency_outputs,
             encoding_booster_input_opts(context)
           ),
         {:ok, output_path} <- build_output_path(tmp_dir, context.container),
         {:ok, encoding_profile} <- production_encoding_profile(context),
         {:ok, timing} <-
           booster_adapter(profile).encode_to_file(
             input_url,
             output_path,
             encoding_booster_options(input_url, encoding_profile)
           ),
         :ok <- StepSupport.validate_media_file(output_path, :video),
         {:ok, %{size: size}} <- File.stat(output_path),
         {:ok, _result} <-
           context.storage_adapter.put_file_public(
             context.bucket,
             context.key,
             output_path,
             media_type(context.container),
             context.region
           ) do
      prefix = if profile == :gpu, do: "gpu_encoding_booster", else: "encoding_booster"
      report_encoding_booster_progress(context, timing, prefix)

      metadata =
        %{
          prefix => true,
          "#{prefix}_elapsed_ms" => Map.get(timing, :elapsed_ms, 0),
          "encoding_profile" => ProductionEncodingProfile.name()
        }
        |> maybe_put_booster_instance(prefix, timing)

      {:ok, %{file_size: size, uri: "s3://#{context.bucket}/#{context.key}"}, prefix, metadata}
    else
      {:error, reason} -> {:error, reason}
    end
  end

  defp encoding_booster_options(input_url, encoding_profile) do
    encoding_profile.request_options
    |> maybe_add_encoding_booster_referer(input_url)
  end

  defp encoding_booster_upload_progress(context) do
    fn total_bytes ->
      StepSupport.report_progress(context.progress_reporter, %{
        "source" => "encoding_booster",
        "executor" => "encoding_booster",
        "status" => "encoding",
        "stage" => "transcode",
        "step_id" => context.step_id,
        "codec" => context.codec,
        "size" => context.size,
        "container" => context.container,
        "total_size_bytes" => total_bytes
      })
    end
  end

  defp estimated_booster_output_bytes(context, video_bitrate) do
    duration_ms = booster_duration_ms(context) || 3_600_000
    video_bits_per_second = bitrate_bits_per_second(video_bitrate)

    audio_bits_per_second =
      if clip_rendition?(context.codec, context.keyframe_interval), do: 0, else: 128_000

    round(
      (video_bits_per_second + audio_bits_per_second) * duration_ms / 8_000 *
        @booster_output_capacity_multiplier
    ) +
      8 * 1024 * 1024
  end

  defp booster_output_capacity_bytes(context, video_bitrate) do
    max(
      estimated_booster_output_bytes(context, video_bitrate),
      dense_keyframe_output_capacity_bytes(context)
    )
  end

  defp dense_keyframe_output_capacity_bytes(%{codec: "h264", keyframe_interval: 2} = context) do
    long_edge = encoding_target_long_edge(context) || @sd_long_edge

    div(
      @dense_keyframe_sd_capacity_bytes * long_edge * long_edge,
      @sd_long_edge * @sd_long_edge
    )
  end

  defp dense_keyframe_output_capacity_bytes(_context), do: 0

  defp bitrate_bits_per_second(value) when is_binary(value) do
    case Regex.run(~r/\A([1-9][0-9]*)([kKmM])\z/, value, capture: :all_but_first) do
      [number, unit] ->
        multiplier = if String.downcase(unit) == "m", do: 1_000_000, else: 1_000
        String.to_integer(number) * multiplier

      _other ->
        8_000_000
    end
  end

  defp production_encoding_profile(context) do
    ProductionEncodingProfile.video_rendition(
      context.codec,
      context.size,
      context.keyframe_interval,
      encoding_target_long_edge(context)
    )
  end

  defp report_encoding_booster_progress(context, timing, executor) do
    total_ms = booster_duration_ms(context)
    ffmpeg_elapsed_ms = Map.get(timing, :ffmpeg_elapsed_ms) || Map.get(timing, :elapsed_ms)
    encoder = production_encoder_metadata(context)

    progress =
      %{
        "source" => "ffmpeg",
        "executor" => executor,
        "status" => "completed",
        "stage" => "transcode",
        "step_id" => context.step_id,
        "codec" => context.codec,
        "size" => context.size,
        "container" => context.container,
        "variants" => [context.size],
        "preset" => Map.get(encoder, "preset"),
        "tune" => Map.get(encoder, "tune"),
        "encoding_profile" => ProductionEncodingProfile.name(),
        "percent" => 100.0,
        "total_ms" => total_ms,
        "ffmpeg_elapsed_ms" => ffmpeg_elapsed_ms,
        "fps" => Map.get(timing, :fps),
        "speed_x" =>
          Map.get(timing, :speed_x) || derived_booster_speed_x(total_ms, ffmpeg_elapsed_ms),
        "frame" => Map.get(timing, :frames),
        "out_time_ms" => Map.get(timing, :out_time_ms),
        "total_size_bytes" => Map.get(timing, :output_bytes) || Map.get(timing, :size_bytes),
        "dup_frames" => Map.get(timing, :dup_frames),
        "drop_frames" => Map.get(timing, :drop_frames),
        "force" => true
      }
      |> Enum.reject(fn {_key, value} -> is_nil(value) end)
      |> Map.new()

    StepSupport.report_progress(context.progress_reporter, progress)
  end

  defp booster_duration_ms(context) do
    inspected_ms = inspect_duration_ms(context.dependency_outputs)

    case production_max_duration(context) do
      seconds when is_integer(seconds) and is_integer(inspected_ms) ->
        min(inspected_ms, seconds * 1000)

      seconds when is_integer(seconds) ->
        seconds * 1000

      _other ->
        inspected_ms
    end
  end

  defp production_encoder_metadata(context) do
    case production_encoding_profile(context) do
      {:ok, profile} -> profile.encoder
      {:error, _reason} -> %{"profile" => ProductionEncodingProfile.name()}
    end
  end

  defp production_max_duration(context) do
    case production_encoding_profile(context) do
      {:ok, profile} -> Keyword.get(profile.request_options, :max_duration_seconds)
      {:error, _reason} -> nil
    end
  end

  defp derived_booster_speed_x(total_ms, ffmpeg_elapsed_ms)
       when is_integer(total_ms) and is_integer(ffmpeg_elapsed_ms) and ffmpeg_elapsed_ms > 0 do
    total_ms / ffmpeg_elapsed_ms
  end

  defp derived_booster_speed_x(_total_ms, _ffmpeg_elapsed_ms), do: nil

  defp booster_adapter(:gpu),
    do: Application.get_env(:mave_core, :gpu_encoding_booster_adapter, GpuEncodingBooster)

  defp booster_adapter(:cpu),
    do: Application.get_env(:mave_core, :encoding_booster_adapter, EncodingBooster)

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

  defp maybe_put_booster_instance(metadata, prefix, timing) do
    case Map.get(timing, :instance_id) do
      instance_id when is_binary(instance_id) ->
        Map.put(metadata, "#{prefix}_instances", [instance_id])

      _other ->
        metadata
    end
  end

  defp maybe_put_fallback(metadata, _key, nil), do: metadata
  defp maybe_put_fallback(metadata, key, code), do: Map.put(metadata, key, code)

  defp encoding_booster_error_code(:encoding_booster_busy), do: "busy"
  defp encoding_booster_error_code(:encoding_booster_not_ready), do: "not_ready"

  defp encoding_booster_error_code({:encoding_booster_not_ready, _status}),
    do: "not_ready"

  defp encoding_booster_error_code({:encoding_booster_http_status, status}),
    do: "http_#{status}"

  defp encoding_booster_error_code(:encoding_booster_empty_response), do: "empty_response"
  defp encoding_booster_error_code(:encoding_booster_empty_remux), do: "remux_failed"
  defp encoding_booster_error_code(:encoding_booster_ffmpeg_not_found), do: "remux_failed"
  defp encoding_booster_error_code({:encoding_booster_remux_failed, _reason}), do: "remux_failed"
  defp encoding_booster_error_code(:encoding_booster_remux_failed), do: "remux_failed"
  defp encoding_booster_error_code(_reason), do: "request_failed"

  defp transcode_with_ffmpeg(context) do
    StepSupport.with_temp_dir("transcode_video", fn tmp_dir ->
      progress =
        ffmpeg_progress(
          context.progress_reporter,
          context.dependency_outputs,
          context.codec,
          context.size,
          context.container,
          context.step_id
        )

      report_transcode_started(progress)

      with {:ok, output_path} <- build_output_path(tmp_dir, context.container),
           {:ok, ffmpeg_output, fallback?} <-
             StepSupport.run_ffmpeg_with_storage_fallback(
               tmp_dir,
               context.run_input,
               context.source_url,
               context.dependency_outputs,
               &build_ffmpeg_args(
                 &1,
                 output_path,
                 context.codec,
                 context.size,
                 context.container,
                 context.keyframe_interval,
                 encoding_target_long_edge(context)
               ),
               ffmpeg_input_opts(context, output_path, progress)
             ),
           {:ok, rendition_body} <- StepSupport.read_tmp_file(output_path) do
        {:ok, rendition_body, "ffmpeg",
         %{"ffmpeg_output" => truncate(ffmpeg_output, 500)}
         |> Map.merge(StepSupport.ffmpeg_fallback_metadata(fallback?))}
      else
        {:error, {ffmpeg_output, status}} when is_binary(ffmpeg_output) and is_integer(status) ->
          {:error, {:ffmpeg_exit, status, truncate(ffmpeg_output, 1000)}}

        {:error, reason} ->
          {:error, reason}
      end
    end)
  end

  defp build_output_path(tmp_dir, container) do
    with {:ok, container} <- StepSupport.require_binary(container, :container) do
      StepSupport.tmp_file_path(tmp_dir, "output", container)
    end
  end

  defp ffmpeg_input_opts(_context, output_path, progress) do
    [
      validate_output: fn -> StepSupport.validate_media_file(output_path, :video) end,
      command_timeout_ms: video_command_timeout_ms(),
      progress: progress
    ]
  end

  defp encoding_booster_input_opts(_context), do: [prefer_source_storage: true]

  defp video_command_timeout_ms do
    Application.get_env(:mave_core, :media_transcode_video_command_timeout_ms)
  end

  defp ffmpeg_progress(nil, _dependency_outputs, _codec, _size, _container, _step_id), do: nil

  defp ffmpeg_progress(progress_reporter, dependency_outputs, codec, size, container, step_id) do
    %{
      reporter: progress_reporter,
      stage: "transcode",
      step_id: step_id,
      codec: codec,
      size: size,
      container: container,
      total_ms: inspect_duration_ms(dependency_outputs)
    }
  end

  defp report_transcode_started(nil), do: :ok

  defp report_transcode_started(progress) do
    StepSupport.report_progress(progress.reporter, %{
      "source" => "ffmpeg",
      "status" => "started",
      "stage" => progress.stage,
      "step_id" => progress.step_id,
      "codec" => progress.codec,
      "size" => progress.size,
      "container" => progress.container,
      "percent" => 1.0,
      "total_ms" => progress.total_ms,
      "force" => true
    })
  end

  defp inspect_duration_ms(dependency_outputs) do
    dependency_outputs
    |> map_get("inspect_media", %{})
    |> map_get("duration")
    |> duration_ms()
  end

  defp inspect_duration(dependency_outputs) do
    dependency_outputs
    |> map_get("inspect_media", %{})
    |> map_get("duration")
  end

  defp duration_ms(value) when is_integer(value), do: value * 1000
  defp duration_ms(value) when is_float(value), do: round(value * 1000)

  defp duration_ms(value) when is_binary(value) do
    case Float.parse(value) do
      {parsed, _rest} -> duration_ms(parsed)
      :error -> nil
    end
  end

  defp duration_ms(_value), do: nil

  defp build_ffmpeg_args(
         input_ref,
         output_path,
         codec,
         size,
         _container,
         keyframe_interval,
         target_long_edge
       ) do
    with {:ok, ffmpeg_codec} <- ffmpeg_video_codec(codec),
         {:ok, ffmpeg_scale} <- legacy_scale(size, target_long_edge),
         {:ok, ffmpeg_bandwidth} <- legacy_bandwidth(codec, size),
         {:ok, profile_args} <-
           video_profile_args(
             codec,
             ffmpeg_codec,
             ffmpeg_scale,
             ffmpeg_bandwidth,
             keyframe_interval
           ) do
      {:ok,
       [
         "-hide_banner",
         "-nostats",
         "-progress",
         "pipe:1",
         "-y",
         "-i",
         input_ref,
         "-map_metadata",
         "-1"
       ] ++
         profile_args ++ [output_path]}
    end
  end

  defp source_copy_inspect_output(%{dependency_outputs: dependency_outputs}) do
    case map_get(dependency_outputs, "inspect_media") do
      %{} = inspect_output ->
        if map_get(inspect_output, "status") == "ok" do
          {:ok, inspect_output}
        else
          {:error, :missing_compatible_inspect_output}
        end

      _other ->
        {:error, :missing_compatible_inspect_output}
    end
  end

  defp ensure_h264_mp4_source(inspect_output, run_input) do
    cond do
      normalize_codec(map_get(inspect_output, "video_codec")) != "h264" ->
        {:error, :source_video_codec_not_h264}

      not source_audio_copy_compatible?(inspect_output) ->
        {:error, :source_audio_codec_not_copy_compatible}

      not source_mp4_container?(inspect_output, run_input) ->
        {:error, :source_container_not_mp4}

      true ->
        :ok
    end
  end

  defp source_audio_copy_compatible?(inspect_output) do
    inspect_output
    |> map_get("audio_codec")
    |> normalize_codec()
    |> case do
      nil -> true
      "aac" -> true
      _other -> false
    end
  end

  defp source_mp4_container?(inspect_output, run_input) do
    filetype =
      inspect_output
      |> map_get("filetype")
      |> normalize_param(nil)
      |> normalize_extension()

    format_name =
      inspect_output
      |> map_get("format_name")
      |> normalize_param("")

    content_type =
      run_input
      |> map_get("source_content_type")
      |> normalize_param("")
      |> String.split(";")
      |> List.first()
      |> String.trim()
      |> String.downcase()

    filetype in ["mp4", "m4v"] or String.contains?(format_name, "mp4") or
      content_type == "video/mp4"
  end

  defp ensure_source_fits_size(inspect_output, size) do
    with {:ok, target_long_edge} <- source_copy_target_long_edge(size),
         source_long_edge when is_integer(source_long_edge) <-
           RenditionSizing.source_long_edge(inspect_output),
         true <- source_long_edge <= target_long_edge do
      :ok
    else
      _ -> {:error, :source_exceeds_target_size}
    end
  end

  defp source_copy_target_long_edge(size) do
    case Map.get(@source_copy_long_edges, size) do
      :infinity -> {:ok, 1_000_000_000}
      nil -> RenditionSizing.target_long_edge(size)
    end
  end

  defp source_resolution_below_variant?(params, dependency_outputs, size) do
    if conditional_size?(params) do
      dependency_outputs
      |> inspected_source_metadata()
      |> RenditionSizing.source_below_variant?(size)
    else
      false
    end
  end

  defp conditional_size?(params) do
    params
    |> Map.get("conditional_size", Map.get(params, "conditional_sizes", true))
    |> truthy?()
  end

  defp inspected_source_metadata(dependency_outputs) do
    dependency_outputs
    |> map_get("inspect_media", %{})
  end

  defp uploaded_original_reference(run_input, dependency_outputs) do
    upload_output = map_get(dependency_outputs, "upload_original", %{})
    bucket = map_get(upload_output, "bucket")
    key = map_get(upload_output, "original_key")
    region = map_get(upload_output, "region") || map_get(run_input, "region")

    if binary_present?(bucket) and binary_present?(key) do
      {:ok, bucket, key, region}
    else
      {:error, :missing_uploaded_original}
    end
  end

  defp ensure_same_storage_profile(region, region), do: :ok
  defp ensure_same_storage_profile(nil, _region), do: :ok
  defp ensure_same_storage_profile(_region, nil), do: :ok

  defp ensure_same_storage_profile(_source_region, _destination_region),
    do: {:error, :storage_profile_mismatch}

  defp source_object_size(storage_adapter, bucket, key, region, inspect_output) do
    case storage_object_size(storage_adapter, bucket, key, region) do
      {:ok, size} ->
        {:ok, size}

      {:error, _reason} ->
        positive_integer(map_get(inspect_output, "size_bytes"))
    end
  end

  defp storage_object_size(storage_adapter, bucket, key, region) do
    if function_exported?(storage_adapter, :object_info, 3) do
      case storage_adapter.object_info(bucket, key, region) do
        {:ok, info} -> positive_integer(map_get(info, "size_bytes"))
        {:error, reason} -> {:error, reason}
      end
    else
      {:error, :object_info_not_supported}
    end
  end

  defp copy_source_public(storage_adapter, bucket, key, source_bucket, source_key, region) do
    if function_exported?(storage_adapter, :copy_public, 5) do
      storage_adapter.copy_public(bucket, key, source_bucket, source_key, region)
    else
      {:error, :copy_public_not_supported}
    end
  end

  defp ffmpeg_video_codec("h264"), do: {:ok, "libx264"}
  defp ffmpeg_video_codec("hevc"), do: {:ok, "libx265"}
  defp ffmpeg_video_codec("av1"), do: {:ok, "libsvtav1"}
  defp ffmpeg_video_codec(other), do: {:error, {:unsupported_codec, other}}

  defp legacy_scale("source"), do: {:ok, RenditionSizing.normalize_sar_filter()}
  defp legacy_scale("original"), do: {:ok, RenditionSizing.normalize_sar_filter()}
  defp legacy_scale(nil), do: RenditionSizing.long_edge_scale_filter("sd")

  defp legacy_scale(size) do
    case RenditionSizing.long_edge_scale_filter(size) do
      {:ok, scale_filter} -> {:ok, scale_filter}
      {:error, _reason} -> RenditionSizing.long_edge_scale_filter("sd")
    end
  end

  defp legacy_scale(_size, target_long_edge) when is_integer(target_long_edge),
    do: {:ok, RenditionSizing.long_edge_scale_filter(target_long_edge)}

  defp legacy_scale(size, _target_long_edge), do: legacy_scale(size)

  defp legacy_bandwidth("hevc", size) do
    {:ok,
     Map.get(
       %{"sd" => "1M", "hd" => "2M", "fhd" => "4M", "qhd" => "6M", "uhd" => "8M"},
       size,
       "1M"
     )}
  end

  defp legacy_bandwidth(_codec, size) do
    {:ok,
     Map.get(
       %{"sd" => "2M", "hd" => "4M", "fhd" => "8M", "qhd" => "12M", "uhd" => "16M"},
       size,
       "2M"
     )}
  end

  defp video_profile_args("hevc", ffmpeg_codec, ffmpeg_scale, ffmpeg_bandwidth, 2) do
    {:ok,
     [
       "-c:v",
       ffmpeg_codec,
       "-g",
       "2",
       "-preset",
       "medium",
       "-vf",
       ffmpeg_scale,
       "-b:v",
       ffmpeg_bandwidth,
       "-movflags",
       "faststart",
       "-tag:v",
       "hvc1"
     ] ++
       audio_args("hevc", 2) ++
       [
         "-t",
         "10"
       ]}
  end

  defp video_profile_args(
         "hevc",
         ffmpeg_codec,
         ffmpeg_scale,
         _ffmpeg_bandwidth,
         keyframe_interval
       ) do
    {:ok,
     [
       "-c:v",
       ffmpeg_codec,
       "-preset",
       "medium",
       "-tune",
       "grain",
       "-crf",
       "24",
       "-vf",
       ffmpeg_scale,
       "-movflags",
       "faststart",
       "-tag:v",
       "hvc1"
     ] ++
       audio_args("hevc", keyframe_interval) ++
       [
         "-t",
         "60"
       ]}
  end

  defp video_profile_args("av1", ffmpeg_codec, ffmpeg_scale, _ffmpeg_bandwidth, keyframe_interval) do
    {:ok,
     [
       "-c:v",
       ffmpeg_codec,
       "-svtav1-params",
       "pin-threads=0:set-thread-priority=0:no-set-thread-priority=1:hierarchical-levels=4:tile-threads=0:log-level=1:tune=0",
       "-crf",
       "26",
       "-preset",
       "6",
       "-vf",
       ffmpeg_scale,
       "-t",
       "60"
     ] ++
       audio_args("av1", keyframe_interval) ++
       [
         "-g",
         Integer.to_string(max(keyframe_interval, 1))
       ]}
  end

  defp video_profile_args("h264", ffmpeg_codec, ffmpeg_scale, ffmpeg_bandwidth, 2) do
    {:ok,
     [
       "-c:v",
       ffmpeg_codec,
       "-crf",
       "23",
       "-g",
       "2",
       "-vf",
       ffmpeg_scale,
       "-b:v",
       ffmpeg_bandwidth,
       "-movflags",
       "faststart"
     ] ++
       audio_args("h264", 2) ++
       [
         "-t",
         "10"
       ]}
  end

  defp video_profile_args(
         "h264",
         ffmpeg_codec,
         ffmpeg_scale,
         ffmpeg_bandwidth,
         keyframe_interval
       ) do
    {:ok,
     [
       "-c:v",
       ffmpeg_codec,
       "-preset",
       "faster",
       "-tune",
       "grain",
       "-vf",
       ffmpeg_scale,
       "-b:v",
       ffmpeg_bandwidth,
       "-movflags",
       "faststart"
     ] ++
       audio_args("h264", keyframe_interval) ++
       [
         "-force_key_frames",
         "expr:gte(t,n_forced*2)"
       ]}
  end

  defp audio_args(codec, keyframe_interval) do
    if clip_rendition?(codec, keyframe_interval) do
      ["-an"]
    else
      ["-c:a", "aac", "-b:a", "128k"]
    end
  end

  defp clip_rendition?(_codec, keyframe_interval) when keyframe_interval == 2, do: true
  defp clip_rendition?(codec, _keyframe_interval) when codec in ["hevc", "av1"], do: true
  defp clip_rendition?(_codec, _keyframe_interval), do: false

  defp build_key(embed_hash, version, codec, size, container, keyframe_interval) do
    with {:ok, embed_hash} <- StepSupport.require_binary(embed_hash, :embed_hash) do
      suffix =
        cond do
          keyframe_interval == 2 -> "_clip_keyframes"
          codec in ["hevc", "av1"] -> "_clip"
          true -> ""
        end

      filename = "#{codec}_#{size}#{suffix}.#{container}"

      key =
        if StepSupport.normalize_version(version) > 0 do
          "#{embed_hash}/v#{StepSupport.normalize_version(version)}/#{filename}"
        else
          "#{embed_hash}/#{filename}"
        end

      {:ok, key}
    end
  end

  defp rendition_type(_codec, keyframe_interval) when keyframe_interval == 2, do: "clip_keyframes"
  defp rendition_type(codec, _keyframe_interval) when codec in ["hevc", "av1"], do: "clip"
  defp rendition_type(_codec, _keyframe_interval), do: "video"

  defp put_rendition(storage_adapter, bucket, key, body, container, region) do
    case storage_adapter.put_public(bucket, key, body, media_type(container), region) do
      {:ok, _body} -> {:ok, "s3://#{bucket}/#{key}"}
      {:error, reason} -> {:error, {:rendition_upload_failed, reason}}
    end
  end

  defp unavailable_output(step_id, codec, size, container, reason) do
    %{
      "status" => "unavailable",
      "step_type" => "media.transcode_video",
      "mode" => "failed",
      "step_id" => step_id,
      "codec" => codec,
      "size" => size,
      "container" => container,
      "error" => inspect(reason)
    }
  end

  defp skipped_output(step_id, codec, size, container, reason) do
    %{
      "status" => "skipped",
      "step_type" => "media.transcode_video",
      "mode" => "skipped",
      "step_id" => step_id,
      "codec" => codec,
      "size" => size,
      "container" => container,
      "reason" => reason
    }
  end

  defp output_resolution(size, dependency_outputs) do
    dependency_outputs
    |> inspected_source_metadata()
    |> then(&RenditionSizing.scaled_resolution(size, &1))
    |> case do
      {:ok, resolution} -> resolution
      _ -> nil
    end
  end

  defp encoding_target_long_edge(context) do
    context.dependency_outputs
    |> inspected_source_metadata()
    |> then(&RenditionSizing.capped_target_long_edge(context.size, &1))
    |> case do
      {:ok, target_long_edge} -> target_long_edge
      _other -> nil
    end
  end

  defp artifact_name(codec, size), do: "video_#{codec}_#{size}"

  defp media_type("mp4"), do: "video/mp4"
  defp media_type("mkv"), do: "video/x-matroska"
  defp media_type("webm"), do: "video/webm"
  defp media_type(_), do: "application/octet-stream"

  defp truthy?(value), do: value in [true, "true", "1", 1]

  defp binary_present?(value), do: is_binary(value) and String.trim(value) != ""

  defp positive_integer(value) when is_integer(value) and value > 0, do: {:ok, value}

  defp positive_integer(value) when is_binary(value) do
    case Integer.parse(value) do
      {parsed, _rest} when parsed > 0 -> {:ok, parsed}
      _ -> {:error, :invalid_positive_integer}
    end
  end

  defp positive_integer(_value), do: {:error, :invalid_positive_integer}

  defp normalize_codec(nil), do: nil

  defp normalize_codec(value) do
    value
    |> to_string()
    |> String.downcase()
  end

  defp normalize_extension(nil), do: nil

  defp normalize_extension(value) do
    value
    |> to_string()
    |> String.trim_leading(".")
    |> String.downcase()
  end

  defp map_get(nil, _key, default), do: default

  defp map_get(map, key, default) when is_map(map) do
    case Map.fetch(map, key) do
      {:ok, value} ->
        value

      :error ->
        map
        |> Map.keys()
        |> Enum.find_value(default, &map_atom_string_value(map, &1, key))
    end
  end

  defp map_get(_map, _key, default), do: default

  defp map_get(nil, _key), do: nil

  defp map_get(map, key) when is_map(map) do
    map_get(map, key, nil)
  end

  defp map_get(_map, _key), do: nil

  defp map_atom_string_value(map, map_key, key) when is_atom(map_key) do
    if Atom.to_string(map_key) == key, do: Map.get(map, map_key), else: nil
  end

  defp map_atom_string_value(_map, _map_key, _key), do: nil

  defp normalize_param(nil, default), do: default
  defp normalize_param(value, _default) when is_binary(value) and value != "", do: value
  defp normalize_param(value, _default) when is_atom(value), do: Atom.to_string(value)
  defp normalize_param(_value, default), do: default

  defp normalize_integer(value) when is_integer(value), do: value

  defp normalize_integer(value) when is_binary(value) do
    case Integer.parse(value) do
      {parsed, ""} -> parsed
      _ -> nil
    end
  end

  defp normalize_integer(_), do: nil

  defp truncate(value, max) when is_binary(value) and is_integer(max) and max > 3 do
    if String.length(value) <= max do
      value
    else
      String.slice(value, 0, max - 3) <> "..."
    end
  end

  defp truncate(value, _max), do: inspect(value)
end
