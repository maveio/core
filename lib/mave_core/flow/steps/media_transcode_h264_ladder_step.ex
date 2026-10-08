defmodule MaveCore.Flow.Steps.MediaTranscodeH264LadderStep do
  @moduledoc """
  Produces one or more H.264 MP4 renditions from an FFmpeg invocation.

  Each output remains addressable by size so presets can either group renditions
  for local FFmpeg execution or schedule one rendition per serverless job.
  """
  @behaviour MaveCore.Flow.Step

  require Logger

  alias MaveCore.EncodingBooster
  alias MaveCore.EncodingBooster.Chunking, as: BoosterChunking
  alias MaveCore.Flow.Steps.MediaPackageHlsVariantStep
  alias MaveCore.Flow.Steps.Support, as: StepSupport
  alias MaveCore.GpuEncodingBooster
  alias MaveCore.Media.{ProductionEncodingProfile, RenditionSizing}
  alias MaveCore.Media.Storage

  @supported_modes ~w(auto copy ffmpeg)
  @default_sizes ~w(sd hd)
  @default_x264_preset "veryfast"
  @x264_presets ~w(ultrafast superfast veryfast faster fast medium slow slower veryslow placebo)
  @x264_tunes ~w(film animation grain stillimage fastdecode zerolatency psnr ssim)
  @prepackaged_frame_specs [
    %{"role" => "poster", "codec" => "jpg"},
    %{"role" => "thumbnail", "codec" => "jpg"},
    %{"role" => "placeholder", "codec" => "jpg"}
  ]
  @prepackaged_frame_roles ~w(poster thumbnail placeholder)
  @prepackaged_frame_codecs ~w(jpg jpeg)
  @frame_prepackage_timeout_ms 120_000
  @booster_output_capacity_multiplier 2.0
  @poster_scale_filter RenditionSizing.normalize_sar_filter()
  @profiles %{
    "sd" => %{bandwidth: "2M"},
    "hd" => %{bandwidth: "4M"},
    "fhd" => %{bandwidth: "8M"},
    "qhd" => %{bandwidth: "12M"},
    "uhd" => %{bandwidth: "16M"}
  }

  @impl true
  def run(step_definition, context) do
    run_input = Map.get(context, :run_input, %{})
    dependency_outputs = Map.get(context, :dependency_outputs, %{})
    progress_reporter = Map.get(context, :progress_reporter)
    source = Map.get(dependency_outputs, "source", %{})
    params = Map.get(step_definition, "params", %{})
    step_id = Map.get(step_definition, "id", "video_h264_ladder")

    source_url =
      Map.get(source, "source_url") || Map.get(run_input, "input_url") ||
        Map.get(run_input, "source_url")

    space_hash = Map.get(source, "space_hash") || Map.get(run_input, "space_hash")
    embed_hash = Map.get(source, "embed_hash") || Map.get(run_input, "embed_hash")
    version = Map.get(source, "version") || Map.get(run_input, "version", 0)
    region = Map.get(run_input, "region")
    container = normalize_param(Map.get(params, "container"), "mp4")
    requested_sizes = configured_sizes(params)
    sizes = active_sizes(requested_sizes, dependency_outputs, params)
    skipped_sizes = requested_sizes -- sizes

    mode =
      StepSupport.normalize_mode(run_input, "media_transcode_h264_ladder_mode", @supported_modes)

    strict? = StepSupport.strict_enabled?(params, run_input, "media_transcode_h264_ladder_strict")
    storage_adapter = Application.get_env(:mave_core, :flow_storage_adapter, Storage)
    bucket = Storage.bucket_for_space(space_hash, region)

    keyframe_interval =
      normalize_integer(Map.get(params, "keyframe_interval")) ||
        normalize_integer(Map.get(run_input, "keyframe_interval")) || 250

    encoder_settings = encoder_settings(params, run_input)
    audio_strategy = ladder_audio_strategy(dependency_outputs)

    run_ladder(%{
      run_input: run_input,
      dependency_outputs: dependency_outputs,
      source_url: source_url,
      space_hash: space_hash,
      embed_hash: embed_hash,
      version: version,
      region: region,
      container: container,
      requested_sizes: requested_sizes,
      sizes: sizes,
      skipped_sizes: skipped_sizes,
      keyframe_interval: keyframe_interval,
      encoder_settings: encoder_settings,
      audio_strategy: audio_strategy,
      frame_prepackage_specs: frame_prepackage_specs(params),
      strict?: strict?,
      storage_adapter: storage_adapter,
      bucket: bucket,
      step_id: step_id,
      mode: mode,
      progress_reporter: progress_reporter,
      execution_metadata: Map.get(context, :execution_metadata, %{}),
      gpu_encoding_booster_dispatch: Map.get(context, :gpu_encoding_booster_dispatch),
      gpu_encoding_booster_fallback_code: Map.get(context, :gpu_encoding_booster_fallback_code),
      encoding_booster_dispatch: Map.get(context, :encoding_booster_dispatch),
      encoding_booster_fallback_code: Map.get(context, :encoding_booster_fallback_code)
    })
  end

  defp run_ladder(context) do
    cond do
      StepSupport.inspect_reports_no_video?(context.dependency_outputs) ->
        {:ok,
         skipped_output(context.step_id, context.sizes, context.container, "no video stream"), []}

      context.sizes == [] ->
        {:ok,
         skipped_output(
           context.step_id,
           context.sizes,
           context.container,
           "source_resolution_below_variant"
         ), []}

      true ->
        transcode_ladder(context)
    end
  end

  defp transcode_ladder(context) do
    with {:ok, space_hash} <- StepSupport.require_binary(context.space_hash, :space_hash),
         {:ok, embed_hash} <- StepSupport.require_binary(context.embed_hash, :embed_hash),
         {:ok, source_url} <- StepSupport.require_binary(context.source_url, :source_url),
         {:ok, variants} <-
           build_variants(
             embed_hash,
             context.version,
             context.sizes,
             context.container,
             context.keyframe_interval
           ),
         variants <- attach_variant_resolutions(variants, context.dependency_outputs),
         {:ok, uploaded_variants, actual_mode, mode_meta} <-
           put_or_copy_variants(
             %{
               context
               | source_url: source_url,
                 space_hash: space_hash,
                 embed_hash: embed_hash
             },
             variants
           ) do
      output = output(context, variants, uploaded_variants, actual_mode, mode_meta)
      artifacts = artifacts(uploaded_variants, context, space_hash, embed_hash)

      {:ok, output, artifacts}
    else
      {:error, {:encoding_booster_fallback_required, _error_code, _reason} = reason} ->
        {:error, reason}

      {:error, {:gpu_encoding_booster_fallback_required, _error_code, _reason} = reason} ->
        {:error, reason}

      {:error, :encoding_booster_busy} ->
        {:error, {:media_transcode_h264_ladder_failed, :encoding_booster_busy}}

      {:error, reason} when context.strict? ->
        {:error, {:media_transcode_h264_ladder_failed, reason}}

      {:error, reason} ->
        {:ok, unavailable_output(context.step_id, context.sizes, context.container, reason), []}
    end
  end

  defp put_or_copy_variants(context, variants) do
    case maybe_copy_source_variants(context, variants) do
      {:ok, uploaded_variants} ->
        {:ok, uploaded_variants, "copy", %{}}

      :skip ->
        case transcode_variants(context, variants) do
          {:ok, uploaded_variants, actual_mode, mode_meta} ->
            {:ok, uploaded_variants, actual_mode, mode_meta}

          {:error, _reason} = error ->
            error
        end
    end
  end

  defp maybe_copy_source_variants(%{mode: mode} = context, variants)
       when mode in ["auto", "copy"] do
    if Map.has_key?(context.run_input, "source_body") or mode == "copy" do
      case StepSupport.resolve_source_body(
             context.run_input,
             context.source_url,
             context.dependency_outputs
           ) do
        {:ok, source_body} -> put_variant_bodies(context, variants, source_body)
        {:error, reason} -> {:error, reason}
      end
    else
      :skip
    end
  end

  defp maybe_copy_source_variants(_context, _variants), do: :skip

  defp transcode_variants(context, variants) do
    transcode_variants(
      context.gpu_encoding_booster_dispatch,
      context.encoding_booster_dispatch,
      context,
      variants
    )
  end

  defp transcode_variants(:direct, _cpu_dispatch, context, variants) do
    case transcode_with_booster(context, variants, :gpu) do
      {:ok, _uploaded_variants, _actual_mode, _mode_meta} = success ->
        success

      {:error, reason} ->
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
  end

  defp transcode_variants(_gpu_dispatch, :direct, context, variants) do
    case transcode_with_booster(context, variants, :cpu) do
      {:ok, _uploaded_variants, _actual_mode, _mode_meta} = success ->
        success

      {:error, :encoding_booster_busy} = busy ->
        busy

      {:error, reason} ->
        if EncodingBooster.fallback_enabled?() and not chunked_booster_source?(context, :cpu) do
          error_code = encoding_booster_error_code(reason)

          Logger.warning(
            "Encoding booster failed for #{context.step_id}; delegating fallback to FLAME FFmpeg: #{error_code}"
          )

          {:error, {:encoding_booster_fallback_required, error_code, reason}}
        else
          {:error, reason}
        end
    end
  end

  defp transcode_variants(_gpu_dispatch, :fallback, context, variants) do
    case transcode_with_ffmpeg(context, variants) do
      {:ok, uploaded_variants, actual_mode, mode_meta} ->
        {:ok, uploaded_variants, actual_mode,
         Map.put(
           mode_meta,
           "encoding_booster_fallback",
           context.encoding_booster_fallback_code || "request_failed"
         )}

      {:error, _reason} = error ->
        error
    end
  end

  defp transcode_variants(_gpu_dispatch, _cpu_dispatch, context, variants) do
    if EncodingBooster.enabled?() do
      transcode_with_inline_booster_fallback(context, variants)
    else
      transcode_with_ffmpeg(context, variants)
    end
  end

  defp transcode_with_inline_booster_fallback(context, variants) do
    case transcode_with_booster(context, variants, :cpu) do
      {:ok, _uploaded_variants, _actual_mode, _mode_meta} = success ->
        success

      {:error, reason} ->
        maybe_transcode_with_inline_ffmpeg_fallback(context, variants, reason)
    end
  end

  defp maybe_transcode_with_inline_ffmpeg_fallback(
         _context,
         _variants,
         :encoding_booster_busy
       ),
       do: {:error, :encoding_booster_busy}

  defp maybe_transcode_with_inline_ffmpeg_fallback(context, variants, reason) do
    if EncodingBooster.fallback_enabled?() and not chunked_booster_source?(context, :cpu) do
      error_code = encoding_booster_error_code(reason)

      Logger.warning(
        "Encoding booster failed for #{context.step_id}; falling back to FLAME FFmpeg: #{error_code}"
      )

      attach_inline_fallback_metadata(transcode_with_ffmpeg(context, variants), error_code)
    else
      {:error, reason}
    end
  end

  defp attach_inline_fallback_metadata(
         {:ok, uploaded_variants, actual_mode, mode_meta},
         error_code
       ) do
    {:ok, uploaded_variants, actual_mode,
     Map.put(mode_meta, "encoding_booster_fallback", error_code)}
  end

  defp attach_inline_fallback_metadata({:error, _reason} = error, _error_code), do: error

  defp transcode_with_ffmpeg(context, variants) do
    StepSupport.with_temp_dir("transcode_h264_ladder", fn tmp_dir ->
      progress = ffmpeg_progress(context, variants)
      report_transcode_started(progress)

      with {:ok, output_paths} <- build_output_paths(tmp_dir, variants),
           {:ok, ffmpeg_output, fallback?} <-
             StepSupport.run_ffmpeg_with_storage_fallback(
               tmp_dir,
               context.run_input,
               context.source_url,
               context.dependency_outputs,
               &build_ffmpeg_args(
                 &1,
                 variants,
                 output_paths,
                 context.keyframe_interval,
                 context.encoder_settings,
                 context.audio_strategy
               ),
               validate_output: fn -> validate_variant_outputs(output_paths) end,
               command_timeout_ms: video_command_timeout_ms(),
               progress: progress
             ),
           {:ok, uploaded_variants} <- put_variant_files(context, variants, output_paths) do
        local_metadata =
          %{"ffmpeg_output" => truncate(ffmpeg_output, 500)}
          |> Map.put("encoder", encoder_metadata(context.encoder_settings))
          |> Map.merge(StepSupport.ffmpeg_fallback_metadata(fallback?))

        finalize_transcoded_variants(
          context,
          variants,
          output_paths,
          uploaded_variants,
          "ffmpeg",
          local_metadata
        )
      else
        {:error, {ffmpeg_output, status}} when is_binary(ffmpeg_output) and is_integer(status) ->
          {:error, {:ffmpeg_exit, status, truncate(ffmpeg_output, 1000)}}

        {:error, reason} ->
          {:error, reason}
      end
    end)
  end

  defp transcode_with_booster(context, variants, :cpu) do
    with {:ok, input_url} <-
           StepSupport.encoding_booster_input_url(
             context.run_input,
             context.source_url,
             context.dependency_outputs,
             prefer_source_storage: true
           ),
         {:ok, booster_result, uploaded_variants} <-
           encode_booster_variants_to_storage(context, variants, input_url) do
      report_encoding_booster_postprocessing_started(context, variants)
      result = {:ok, uploaded_variants, "encoding_booster", booster_result.metadata}
      maybe_report_encoding_booster_completed(result, context, variants, booster_result.timings)
    end
  end

  defp transcode_with_booster(context, variants, profile) do
    StepSupport.with_temp_dir("transcode_h264_ladder_booster", fn tmp_dir ->
      with {:ok, input_url} <-
             StepSupport.encoding_booster_input_url(
               context.run_input,
               context.source_url,
               context.dependency_outputs,
               prefer_source_storage: true
             ),
           {:ok, output_paths} <- build_output_paths(tmp_dir, variants),
           {:ok, booster_result} <-
             encode_booster_variants(context, variants, input_url, output_paths, profile),
           :ok <- validate_variant_outputs(output_paths),
           {:ok, uploaded_variants} <- put_variant_files(context, variants, output_paths) do
        result =
          maybe_finalize_encoding_booster_variants(
            context,
            variants,
            output_paths,
            uploaded_variants,
            booster_result,
            profile
          )

        maybe_report_encoding_booster_completed(
          result,
          context,
          variants,
          booster_result.timings
        )
      end
    end)
  end

  defp encode_booster_variants_to_storage(context, variants, input_url) do
    variants
    |> Enum.reduce_while({:ok, [], []}, fn variant, {:ok, timings, uploaded} ->
      case encode_booster_variant_to_storage(context, variants, variant, input_url) do
        {:ok, timing, uploaded_variant} ->
          {:cont, {:ok, [{variant.size, timing} | timings], [uploaded_variant | uploaded]}}

        {:error, reason} ->
          {:halt, {:error, reason}}
      end
    end)
    |> case do
      {:ok, timings, uploaded_variants} ->
        timings = Enum.reverse(timings)

        metadata =
          %{
            "encoding_booster" => true,
            "encoding_booster_elapsed_ms" =>
              Enum.reduce(timings, 0, fn {_size, timing}, total ->
                total + Map.get(timing, :elapsed_ms, 0)
              end),
            "encoding_booster_variants" => Enum.map(timings, &elem(&1, 0)),
            "encoder" => production_encoder_metadata(),
            "encoding_booster_storage_direct" => true
          }
          |> maybe_put_encoding_booster_instances(timings, "encoding_booster")
          |> maybe_put_encoding_booster_chunks(timings, "encoding_booster")

        {:ok, %{metadata: metadata, timings: timings}, Enum.reverse(uploaded_variants)}

      {:error, _reason} = error ->
        error
    end
  end

  defp encode_booster_variant_to_storage(context, variants, variant, input_url) do
    {on_chunk, progress_key} = encoding_booster_chunk_progress(context, variants, variant)

    with {:ok, profile} <-
           ProductionEncodingProfile.h264_ladder(
             variant.size,
             context.audio_strategy != :video_only,
             context.keyframe_interval,
             variant.long_edge
           ) do
      options =
        profile.request_options
        |> Keyword.put(:on_chunk, on_chunk)
        |> maybe_add_encoding_booster_referer(input_url)

      try do
        case booster_source_chunks(context, :cpu) do
          [_single_chunk] ->
            encode_booster_object(context, variant.key, input_url, options, variant, 1, false)

          chunks ->
            encode_booster_chunk_objects(context, variant, input_url, options, chunks)
        end
      after
        if progress_key, do: Process.delete(progress_key)
      end
    end
  end

  defp encode_booster_chunk_objects(context, variant, input_url, options, chunks) do
    chunk_keys =
      chunks
      |> Enum.with_index()
      |> Enum.map(fn {chunk, index} ->
        chunk_options =
          options
          |> Keyword.put(:start_seconds, chunk.start_seconds)
          |> Keyword.put(:duration_seconds, chunk.duration_seconds)

        booster_chunk_key(variant.key, chunk_options, index)
      end)

    with {:ok, timings} <-
           encode_booster_storage_chunks(
             context,
             variant,
             input_url,
             options,
             chunks,
             chunk_keys
           ),
         {:ok, chunk_urls} <- booster_chunk_urls(context, chunk_keys),
         {:ok, concat_timing, uploaded} <-
           concat_booster_objects(context, variant, chunk_urls, timings) do
      Enum.each(chunk_keys, fn key ->
        _ = context.storage_adapter.delete_object(context.bucket, key, context.region)
      end)

      {:ok,
       aggregate_booster_chunk_timings(timings, concat_timing, chunks)
       |> Map.put(:size_bytes, uploaded["file_size"])
       |> Map.put(:output_bytes, uploaded["file_size"]), uploaded}
    end
  end

  defp encode_booster_storage_chunks(
         context,
         variant,
         input_url,
         options,
         chunks,
         chunk_keys
       ) do
    chunks
    |> Enum.zip(chunk_keys)
    |> Enum.with_index()
    |> Enum.reduce_while({:ok, [], 0}, fn {{chunk, chunk_key}, index},
                                          {:ok, timings, completed_bytes} ->
      chunk_options =
        options
        |> Keyword.put(:start_seconds, chunk.start_seconds)
        |> Keyword.put(:duration_seconds, chunk.duration_seconds)
        |> Keyword.put(
          :on_chunk,
          BoosterChunking.cumulative_progress(Keyword.get(options, :on_chunk), completed_bytes)
        )

      case encode_booster_object(
             context,
             chunk_key,
             input_url,
             chunk_options,
             variant,
             1,
             true
           ) do
        {:ok, timing, _uploaded} ->
          size_bytes = Map.get(timing, :size_bytes, 0)
          {:cont, {:ok, [timing | timings], completed_bytes + size_bytes}}

        {:error, reason} ->
          {:halt, {:error, {:encoding_booster_chunk_failed, index, reason}}}
      end
    end)
    |> case do
      {:ok, timings, _completed_bytes} -> {:ok, Enum.reverse(timings)}
      {:error, _reason} = error -> error
    end
  end

  defp concat_booster_objects(context, variant, chunk_urls, timings) do
    max_bytes =
      timings
      |> Enum.map(&Map.get(&1, :size_bytes, 0))
      |> Enum.sum()
      |> max(estimated_booster_output_bytes(context, variant))

    with {:ok, session} <-
           context.storage_adapter.start_presigned_multipart_upload(
             context.bucket,
             variant.key,
             context.region,
             media_type(variant.container),
             max_bytes: max_bytes
           ) do
      case encoding_booster_adapter(:cpu).concat_to_storage(
             chunk_urls,
             session.payload,
             []
           ) do
        {:ok, timing} ->
          verified_booster_object(context, variant, timing)

        {:error, reason} ->
          recover_or_abort_booster_object(context, variant, session, reason)
      end
    end
  end

  defp encode_booster_object(
         context,
         key,
         input_url,
         options,
         variant,
         chunk_count,
         reuse_existing?
       ) do
    if reuse_existing? do
      case context.storage_adapter.object_info(context.bucket, key, context.region) do
        {:ok, %{size_bytes: size_bytes}} when is_integer(size_bytes) and size_bytes > 0 ->
          uploaded = uploaded_variant(context, %{variant | key: key}, size_bytes)
          {:ok, %{elapsed_ms: 0, size_bytes: size_bytes, chunk_count: chunk_count}, uploaded}

        _other ->
          start_booster_object_upload(context, key, input_url, options, variant)
      end
    else
      start_booster_object_upload(context, key, input_url, options, variant)
    end
  end

  defp start_booster_object_upload(context, key, input_url, options, variant) do
    with {:ok, session} <-
           context.storage_adapter.start_presigned_multipart_upload(
             context.bucket,
             key,
             context.region,
             media_type(variant.container),
             max_bytes: estimated_booster_output_bytes(context, variant, options)
           ) do
      upload_booster_object(context, %{variant | key: key}, input_url, options, session)
    end
  end

  defp upload_booster_object(context, variant, input_url, options, session) do
    case encoding_booster_adapter(:cpu).encode_to_storage(input_url, session.payload, options) do
      {:ok, timing} -> verified_booster_object(context, variant, timing)
      {:error, reason} -> recover_or_abort_booster_object(context, variant, session, reason)
    end
  end

  defp recover_or_abort_booster_object(context, _variant, session, reason) do
    _ = context.storage_adapter.abort_presigned_multipart_upload(session)
    {:error, reason}
  end

  defp verified_booster_object(context, variant, timing) do
    case context.storage_adapter.object_info(context.bucket, variant.key, context.region) do
      {:ok, %{size_bytes: size_bytes}} when is_integer(size_bytes) and size_bytes > 0 ->
        {:ok, Map.put(timing, :size_bytes, size_bytes),
         uploaded_variant(context, variant, size_bytes)}

      {:error, reason} ->
        {:error, {:rendition_upload_verification_failed, variant.size, reason}}

      _other ->
        {:error, {:rendition_upload_verification_failed, variant.size, :empty_object}}
    end
  end

  defp booster_chunk_urls(context, chunk_keys) do
    chunk_keys
    |> Enum.reduce_while({:ok, []}, fn key, {:ok, urls} ->
      case context.storage_adapter.presigned_get_url(
             context.bucket,
             key,
             context.region,
             expires: 2 * 60 * 60
           ) do
        {:ok, url} -> {:cont, {:ok, [url | urls]}}
        {:error, reason} -> {:halt, {:error, reason}}
      end
    end)
    |> case do
      {:ok, urls} -> {:ok, Enum.reverse(urls)}
      {:error, _reason} = error -> error
    end
  end

  defp booster_chunk_key(final_key, options, index) do
    BoosterChunking.chunk_key(final_key, options, index)
  end

  defp estimated_booster_output_bytes(context, variant, options \\ []) do
    duration =
      case Keyword.get(options, :duration_seconds) do
        value when is_number(value) and value > 0 -> value
        _other -> inspect_duration_seconds(context.dependency_outputs) || 3_600
      end

    video_bps = bitrate_bits_per_second(variant.profile.bandwidth)
    audio_bps = if context.audio_strategy == :video_only, do: 0, else: 128_000

    round((video_bps + audio_bps) * duration / 8 * @booster_output_capacity_multiplier) +
      8 * 1024 * 1024
  end

  defp bitrate_bits_per_second(value) when is_binary(value) do
    case Regex.run(~r/\A([1-9][0-9]*)([kKmM])\z/, value, capture: :all_but_first) do
      [number, unit] ->
        multiplier = if String.downcase(unit) == "m", do: 1_000_000, else: 1_000
        String.to_integer(number) * multiplier

      _other ->
        8_000_000
    end
  end

  defp maybe_report_encoding_booster_completed(
         {:ok, _uploaded_variants, _actual_mode, _mode_meta} = result,
         context,
         variants,
         timings
       ) do
    report_encoding_booster_completed(context, variants, timings)
    result
  end

  defp maybe_report_encoding_booster_completed(result, _context, _variants, _timings), do: result

  defp maybe_finalize_encoding_booster_variants(
         _context,
         _variants,
         _output_paths,
         uploaded_variants,
         booster_result,
         :gpu
       ) do
    {:ok, uploaded_variants, "gpu_encoding_booster", booster_result.metadata}
  end

  defp maybe_finalize_encoding_booster_variants(
         %{encoding_booster_dispatch: :direct} = context,
         variants,
         output_paths,
         uploaded_variants,
         booster_result,
         :cpu
       ) do
    {hls_outputs, hls_errors} =
      prepackage_hls_variants(context, variants, output_paths, true)

    metadata =
      put_hls_prepackage_metadata(booster_result.metadata, hls_outputs, hls_errors)

    {:ok, attach_hls_outputs(uploaded_variants, hls_outputs), "encoding_booster", metadata}
  end

  defp maybe_finalize_encoding_booster_variants(
         context,
         variants,
         output_paths,
         uploaded_variants,
         booster_result,
         :cpu
       ) do
    finalize_transcoded_variants(
      context,
      variants,
      output_paths,
      uploaded_variants,
      "encoding_booster",
      booster_result.metadata
    )
  end

  defp encode_booster_variants(context, variants, input_url, output_paths, profile) do
    variants
    |> Enum.reduce_while({:ok, []}, fn variant, {:ok, timings} ->
      output_path = Map.fetch!(output_paths, variant.size)

      case encode_booster_variant(context, variants, variant, input_url, output_path, profile) do
        {:ok, timing} ->
          {:cont, {:ok, [{variant.size, timing} | timings]}}

        {:error, reason} ->
          {:halt, {:error, reason}}
      end
    end)
    |> case do
      {:ok, timings} ->
        timings = Enum.reverse(timings)

        if profile == :cpu do
          report_encoding_booster_postprocessing_started(context, variants)
        end

        prefix = if profile == :gpu, do: "gpu_encoding_booster", else: "encoding_booster"

        metadata =
          %{
            prefix => true,
            "#{prefix}_elapsed_ms" =>
              Enum.reduce(timings, 0, fn {_size, timing}, total ->
                total + Map.get(timing, :elapsed_ms, 0)
              end),
            "#{prefix}_variants" => Enum.map(timings, &elem(&1, 0)),
            "encoder" => production_encoder_metadata()
          }
          |> maybe_put_encoding_booster_instances(timings, prefix)
          |> maybe_put_encoding_booster_chunks(timings, prefix)

        {:ok, %{metadata: metadata, timings: timings}}

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp encode_booster_variant(context, variants, variant, input_url, output_path, profile) do
    {on_chunk, progress_key} = encoding_booster_chunk_progress(context, variants, variant)

    with {:ok, encoding_profile} <-
           ProductionEncodingProfile.h264_ladder(
             variant.size,
             context.audio_strategy != :video_only,
             context.keyframe_interval,
             variant.long_edge
           ) do
      options =
        encoding_profile.request_options
        |> Keyword.put(:on_chunk, on_chunk)
        |> maybe_add_encoding_booster_referer(input_url)

      try do
        encode_booster_variant_output(
          context,
          input_url,
          output_path,
          options,
          on_chunk,
          profile
        )
      after
        if progress_key, do: Process.delete(progress_key)
      end
    end
  end

  defp encode_booster_variant_output(
         _context,
         input_url,
         output_path,
         options,
         _on_chunk,
         profile
       ) do
    encoding_booster_adapter(profile).encode_to_file(input_url, output_path, options)
  end

  defp aggregate_booster_chunk_timings(timings, concat_meta, chunks) do
    elapsed_ms = sum_timing(timings, :elapsed_ms)
    ffmpeg_elapsed_ms = sum_timing(timings, :ffmpeg_elapsed_ms)
    total_duration_ms = round(Enum.sum(Enum.map(chunks, & &1.duration_seconds)) * 1_000)
    frames = sum_optional_timing(timings, :frames)

    %{
      elapsed_ms: elapsed_ms,
      ffmpeg_elapsed_ms: ffmpeg_elapsed_ms,
      frames: frames,
      fps: derived_chunk_fps(frames, ffmpeg_elapsed_ms),
      speed_x: derived_booster_speed_x(total_duration_ms, ffmpeg_elapsed_ms),
      out_time_ms: sum_optional_timing(timings, :out_time_ms),
      output_bytes: Map.get(concat_meta, :size_bytes),
      size_bytes: Map.get(concat_meta, :size_bytes),
      dup_frames: sum_optional_timing(timings, :dup_frames),
      drop_frames: sum_optional_timing(timings, :drop_frames),
      instance_ids: timings |> Enum.map(&Map.get(&1, :instance_id)) |> Enum.filter(&is_binary/1),
      chunk_count: length(chunks)
    }
    |> Enum.reject(fn {_key, value} -> is_nil(value) end)
    |> Map.new()
  end

  defp sum_timing(timings, key) do
    Enum.reduce(timings, 0, fn timing, total ->
      case Map.get(timing, key) do
        value when is_number(value) and value > 0 -> total + value
        _other -> total
      end
    end)
  end

  defp sum_optional_timing(timings, key) do
    values = timings |> Enum.map(&Map.get(&1, key)) |> Enum.filter(&is_number/1)
    if values == [], do: nil, else: Enum.sum(values)
  end

  defp derived_chunk_fps(frames, elapsed_ms)
       when is_number(frames) and is_integer(elapsed_ms) and elapsed_ms > 0 do
    frames / (elapsed_ms / 1_000)
  end

  defp derived_chunk_fps(_frames, _elapsed_ms), do: nil

  defp booster_source_chunks(context, profile) do
    duration_seconds = inspect_duration_seconds(context.dependency_outputs)

    if profile == :cpu,
      do: BoosterChunking.source_chunks(duration_seconds),
      else: [%{start_seconds: 0.0, duration_seconds: duration_seconds || 0.0}]
  end

  defp chunked_booster_source?(context, :cpu) do
    context.dependency_outputs
    |> inspect_duration_seconds()
    |> BoosterChunking.source_chunks()
    |> BoosterChunking.chunked?()
  end

  defp chunked_booster_source?(_context, _profile), do: false

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

  defp maybe_put_encoding_booster_instances(metadata, timings, prefix) do
    instance_ids =
      timings
      |> Enum.flat_map(fn {_size, timing} ->
        case Map.get(timing, :instance_ids) do
          ids when is_list(ids) -> ids
          _other -> [Map.get(timing, :instance_id)]
        end
      end)
      |> Enum.filter(&is_binary/1)
      |> Enum.uniq()

    if instance_ids == [],
      do: metadata,
      else: Map.put(metadata, "#{prefix}_instances", instance_ids)
  end

  defp maybe_put_encoding_booster_chunks(metadata, timings, prefix) do
    chunk_count =
      Enum.reduce(timings, 0, fn {_size, timing}, total ->
        total + max(Map.get(timing, :chunk_count, 1), 1)
      end)

    if chunk_count > length(timings),
      do: Map.put(metadata, "#{prefix}_chunks", chunk_count),
      else: metadata
  end

  defp finalize_transcoded_variants(
         context,
         variants,
         output_paths,
         uploaded_variants,
         actual_mode,
         mode_meta
       ) do
    {frame_outputs, frame_errors} = prepackage_frame_outputs(context, variants, output_paths)
    {hls_outputs, hls_errors} = prepackage_hls_variants(context, variants, output_paths)
    uploaded_variants = attach_hls_outputs(uploaded_variants, hls_outputs)

    mode_meta =
      mode_meta
      |> put_frame_prepackage_metadata(frame_outputs, frame_errors)
      |> put_hls_prepackage_metadata(hls_outputs, hls_errors)

    {:ok, uploaded_variants, actual_mode, mode_meta}
  end

  defp report_encoding_booster_progress(context, variants, variant, index, timing) do
    total_ms = inspect_duration_ms(context.dependency_outputs)
    ffmpeg_elapsed_ms = Map.get(timing, :ffmpeg_elapsed_ms) || Map.get(timing, :elapsed_ms)

    progress =
      %{
        "source" => "ffmpeg",
        "executor" => "encoding_booster",
        "status" => "completed",
        "stage" => "transcode",
        "step_id" => context.step_id,
        "codec" => "h264",
        "size" => variant.size,
        "container" => context.container,
        "variants" => Enum.map(variants, & &1.size),
        "preset" => "veryfast",
        "encoding_profile" => ProductionEncodingProfile.name(),
        "percent" => (index + 1) / length(variants) * 100.0,
        "total_ms" => total_ms,
        "ffmpeg_elapsed_ms" => ffmpeg_elapsed_ms,
        "fps" => Map.get(timing, :fps),
        "speed_x" => booster_speed_x(timing, total_ms, ffmpeg_elapsed_ms),
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

  defp report_encoding_booster_completed(context, variants, timings) do
    timings
    |> Enum.with_index()
    |> Enum.each(fn {{size, timing}, index} ->
      case Enum.find(variants, &(&1.size == size)) do
        nil -> :ok
        variant -> report_encoding_booster_progress(context, variants, variant, index, timing)
      end
    end)
  end

  defp report_encoding_booster_postprocessing_started(%{progress_reporter: nil}, _variants),
    do: :ok

  defp report_encoding_booster_postprocessing_started(context, variants) do
    StepSupport.report_progress(context.progress_reporter, %{
      "source" => "encoding_booster",
      "status" => "executing",
      "stage" => "package_hls",
      "step_id" => context.step_id,
      "codec" => "h264",
      "size" => variants |> List.first() |> then(&(&1 && &1.size)),
      "container" => "hls",
      "variants" => Enum.map(variants, & &1.size),
      "preset" => "veryfast",
      "encoding_profile" => ProductionEncodingProfile.name(),
      "percent" => 1.0,
      "total_ms" => inspect_duration_ms(context.dependency_outputs),
      "force" => true
    })
  end

  defp booster_speed_x(timing, total_ms, ffmpeg_elapsed_ms) do
    Map.get(timing, :speed_x) || derived_booster_speed_x(total_ms, ffmpeg_elapsed_ms)
  end

  defp derived_booster_speed_x(total_ms, ffmpeg_elapsed_ms)
       when is_integer(total_ms) and is_integer(ffmpeg_elapsed_ms) and ffmpeg_elapsed_ms > 0 do
    total_ms / ffmpeg_elapsed_ms
  end

  defp derived_booster_speed_x(_total_ms, _ffmpeg_elapsed_ms), do: nil

  defp encoding_booster_chunk_progress(%{progress_reporter: nil}, _variants, _variant),
    do: {nil, nil}

  defp encoding_booster_chunk_progress(context, variants, variant) do
    progress_key = {__MODULE__, :encoding_booster_progress, make_ref()}
    now_ms = System.monotonic_time(:millisecond)
    previous_progress = previous_encoding_booster_progress(context, variant)
    initial_bytes = previous_progress.bytes
    started_at_ms = now_ms - previous_progress.elapsed_ms

    Process.put(progress_key, %{
      last_bytes: initial_bytes,
      last_report_ms: now_ms,
      max_bytes: initial_bytes,
      received_bytes?: initial_bytes > 0,
      started_at_ms: started_at_ms
    })

    report_encoding_booster_live_progress(
      context,
      variants,
      variant,
      initial_bytes,
      initial_bytes,
      started_at_ms,
      now_ms,
      true
    )

    on_chunk = fn total_bytes ->
      now_ms = System.monotonic_time(:millisecond)
      state = Process.get(progress_key)

      case state do
        %{last_bytes: last_bytes, last_report_ms: last_report_ms, received_bytes?: true}
        when total_bytes >= last_bytes and total_bytes - last_bytes < 1_048_576 and
               now_ms - last_report_ms < 1_000 ->
          :ok

        _other ->
          started_at_ms = encoding_booster_progress_started_at(state, now_ms)
          max_bytes = max(total_bytes, encoding_booster_progress_max_bytes(state))

          Process.put(progress_key, %{
            last_bytes: total_bytes,
            last_report_ms: now_ms,
            max_bytes: max_bytes,
            received_bytes?: true,
            started_at_ms: started_at_ms
          })

          report_encoding_booster_live_progress(
            context,
            variants,
            variant,
            total_bytes,
            max_bytes,
            started_at_ms,
            now_ms,
            false
          )
      end
    end

    {on_chunk, progress_key}
  end

  defp previous_encoding_booster_progress(context, variant) do
    progress = get_in(context, [:execution_metadata, "progress"])

    if is_map(progress) and progress["source"] == "encoding_booster" and
         progress["stage"] == "transcode" and progress["size"] == variant.size do
      %{
        bytes: non_negative_progress_integer(progress["total_size_bytes"]),
        elapsed_ms: non_negative_progress_integer(progress["ffmpeg_elapsed_ms"])
      }
    else
      %{bytes: 0, elapsed_ms: 0}
    end
  end

  defp non_negative_progress_integer(value) when is_integer(value) and value >= 0, do: value
  defp non_negative_progress_integer(_value), do: 0

  defp encoding_booster_progress_started_at(%{started_at_ms: existing_started_at_ms}, _now_ms),
    do: existing_started_at_ms

  defp encoding_booster_progress_started_at(_state, now_ms), do: now_ms

  defp encoding_booster_progress_max_bytes(%{max_bytes: max_bytes}) when is_integer(max_bytes),
    do: max_bytes

  defp encoding_booster_progress_max_bytes(_state), do: 0

  defp report_encoding_booster_live_progress(
         context,
         variants,
         variant,
         total_bytes,
         progress_bytes,
         started_at_ms,
         now_ms,
         force?
       ) do
    total_ms = inspect_duration_ms(context.dependency_outputs)
    estimated_total_bytes = encoding_booster_estimated_total_bytes(context, variant, total_ms)
    ratio = encoding_booster_output_ratio(progress_bytes, estimated_total_bytes)
    elapsed_ms = max(now_ms - started_at_ms, 0)

    progress =
      %{
        "source" => "encoding_booster",
        "status" => if(total_bytes > 0, do: "executing", else: "started"),
        "stage" => "transcode",
        "step_id" => context.step_id,
        "codec" => "h264",
        "size" => variant.size,
        "container" => context.container,
        "variants" => Enum.map(variants, & &1.size),
        "preset" => "veryfast",
        "encoding_profile" => ProductionEncodingProfile.name(),
        "percent" => max(ratio * 100.0, 1.0),
        "ratio" => ratio,
        "out_time_ms" => estimated_out_time_ms(total_ms, ratio),
        "total_ms" => total_ms,
        "speed_x" => estimated_booster_speed_x(total_ms, ratio, elapsed_ms),
        "ffmpeg_elapsed_ms" => elapsed_ms,
        "total_size_bytes" => progress_bytes,
        "force" => force?
      }
      |> Enum.reject(fn {_key, value} -> is_nil(value) end)
      |> Map.new()

    StepSupport.report_progress(context.progress_reporter, progress)
  end

  defp encoding_booster_estimated_total_bytes(context, variant, total_ms)
       when is_integer(total_ms) and total_ms > 0 do
    video_bitrate = encoding_booster_bitrate_bps(variant.profile.bandwidth)
    audio_bitrate = if context.audio_strategy == :video_only, do: 0, else: 128_000

    case video_bitrate do
      bitrate when is_integer(bitrate) and bitrate > 0 ->
        round((bitrate + audio_bitrate) * total_ms / 8_000)

      _other ->
        nil
    end
  end

  defp encoding_booster_estimated_total_bytes(_context, _variant, _total_ms), do: nil

  defp encoding_booster_bitrate_bps(value) when is_binary(value) do
    case Regex.run(~r/\A([0-9]+(?:\.[0-9]+)?)([kKmM]?)\z/, String.trim(value)) do
      [_, number, unit] ->
        multiplier =
          case String.downcase(unit) do
            "m" -> 1_000_000
            "k" -> 1_000
            "" -> 1
          end

        case Float.parse(number) do
          {parsed, ""} -> round(parsed * multiplier)
          _other -> nil
        end

      _other ->
        nil
    end
  end

  defp encoding_booster_bitrate_bps(value) when is_integer(value) and value > 0, do: value
  defp encoding_booster_bitrate_bps(_value), do: nil

  defp encoding_booster_output_ratio(total_bytes, estimated_total_bytes)
       when is_integer(total_bytes) and total_bytes >= 0 and is_integer(estimated_total_bytes) and
              estimated_total_bytes > 0 do
    total_bytes
    |> Kernel./(estimated_total_bytes)
    |> min(0.99)
    |> max(0.0)
  end

  defp encoding_booster_output_ratio(_total_bytes, _estimated_total_bytes), do: 0.0

  defp estimated_out_time_ms(total_ms, ratio)
       when is_integer(total_ms) and total_ms > 0 and is_float(ratio),
       do: round(total_ms * ratio)

  defp estimated_out_time_ms(_total_ms, _ratio), do: nil

  defp estimated_booster_speed_x(total_ms, ratio, elapsed_ms)
       when is_integer(total_ms) and total_ms > 0 and is_float(ratio) and ratio > 0 and
              is_integer(elapsed_ms) and elapsed_ms > 0 do
    total_ms * ratio / elapsed_ms
  end

  defp estimated_booster_speed_x(_total_ms, _ratio, _elapsed_ms), do: nil

  defp encoding_booster_adapter(:cpu),
    do: Application.get_env(:mave_core, :encoding_booster_adapter, EncodingBooster)

  defp encoding_booster_adapter(:gpu),
    do: Application.get_env(:mave_core, :gpu_encoding_booster_adapter, GpuEncodingBooster)

  defp encoding_booster_error_code(:encoding_booster_busy), do: "busy"
  defp encoding_booster_error_code(:encoding_booster_not_ready), do: "not_ready"

  defp encoding_booster_error_code({:encoding_booster_not_ready, _status}),
    do: "not_ready"

  defp encoding_booster_error_code({:encoding_booster_http_status, status}),
    do: "http_#{status}"

  defp encoding_booster_error_code({:encoding_booster_http_status, status, _detail}),
    do: "http_#{status}"

  defp encoding_booster_error_code(:encoding_booster_empty_response), do: "empty_response"
  defp encoding_booster_error_code(:encoding_booster_empty_remux), do: "remux_failed"
  defp encoding_booster_error_code(:encoding_booster_ffmpeg_not_found), do: "remux_failed"

  defp encoding_booster_error_code({:encoding_booster_remux_failed, _reason}),
    do: "remux_failed"

  defp encoding_booster_error_code(:encoding_booster_remux_failed), do: "remux_failed"
  defp encoding_booster_error_code(:encoding_booster_input_must_be_https), do: "invalid_input"
  defp encoding_booster_error_code({:unsafe_encoding_booster_input, _reason}), do: "invalid_input"
  defp encoding_booster_error_code(_reason), do: "request_failed"

  defp build_ffmpeg_args(
         input_ref,
         variants,
         output_paths,
         keyframe_interval,
         encoder_settings,
         audio_strategy
       ) do
    with {:ok, filter_complex} <- ladder_filter_complex(variants),
         {:ok, output_args} <-
           ladder_output_args(
             variants,
             output_paths,
             keyframe_interval,
             encoder_settings,
             audio_strategy
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
         "-1",
         "-filter_complex",
         filter_complex
       ] ++ output_args}
    end
  end

  defp ladder_filter_complex([variant]) do
    with {:ok, scale_filter} <- variant_scale_filter(variant) do
      {:ok, "[0:v:0]#{scale_filter}[v_#{variant.size}]"}
    end
  end

  defp ladder_filter_complex(variants) do
    with {:ok, scaled_outputs} <- ladder_scaled_outputs(variants) do
      split_outputs =
        variants
        |> Enum.with_index()
        |> Enum.map_join("", fn {_variant, index} -> "[base#{index}]" end)

      {:ok,
       "[0:v:0]#{RenditionSizing.normalize_sar_filter()},split=#{length(variants)}#{split_outputs};#{scaled_outputs}"}
    end
  end

  defp ladder_scaled_outputs(variants) do
    variants
    |> Enum.with_index()
    |> Enum.reduce_while({:ok, []}, fn {variant, index}, {:ok, acc} ->
      case variant_scale_filter(variant) do
        {:ok, scale_filter} ->
          scaled_output =
            scale_filter
            |> String.replace_prefix("#{RenditionSizing.normalize_sar_filter()},", "")
            |> then(&"[base#{index}]#{&1}[v_#{variant.size}]")

          {:cont, {:ok, [scaled_output | acc]}}

        {:error, reason} ->
          {:halt, {:error, reason}}
      end
    end)
    |> case do
      {:ok, outputs} -> {:ok, outputs |> Enum.reverse() |> Enum.join(";")}
      {:error, reason} -> {:error, reason}
    end
  end

  defp variant_scale_filter(%{long_edge: long_edge})
       when is_integer(long_edge) and long_edge > 0,
       do: {:ok, RenditionSizing.long_edge_scale_filter(long_edge)}

  defp variant_scale_filter(variant),
    do: RenditionSizing.long_edge_scale_filter(variant.size)

  defp ladder_output_args(
         variants,
         output_paths,
         keyframe_interval,
         encoder_settings,
         audio_strategy
       ) do
    {:ok,
     Enum.flat_map(variants, fn variant ->
       [
         "-map",
         "[v_#{variant.size}]"
       ] ++
         audio_mapping_args(audio_strategy) ++
         [
           "-c:v",
           "libx264",
           "-preset",
           encoder_settings.preset
         ] ++
         tune_args(encoder_settings.tune) ++
         [
           "-b:v",
           variant.profile.bandwidth,
           "-movflags",
           "faststart"
         ] ++
         audio_encoding_args(audio_strategy) ++
         [
           "-force_key_frames",
           "expr:gte(t,n_forced*2)",
           "-g",
           Integer.to_string(max(keyframe_interval, 1)),
           Map.fetch!(output_paths, variant.size)
         ]
     end)}
  end

  defp audio_mapping_args(:video_only), do: []
  defp audio_mapping_args(_strategy), do: ["-map", "0:a?"]

  defp audio_encoding_args(:video_only), do: ["-an"]
  defp audio_encoding_args(_strategy), do: ["-c:a", "aac", "-b:a", "128k"]

  defp tune_args(nil), do: []
  defp tune_args(tune), do: ["-tune", tune]

  defp put_variant_bodies(context, variants, body) do
    variants
    |> Enum.reduce_while({:ok, []}, fn variant, {:ok, acc} ->
      case put_variant_body(context, variant, body) do
        {:ok, uploaded} -> {:cont, {:ok, [uploaded | acc]}}
        {:error, reason} -> {:halt, {:error, reason}}
      end
    end)
    |> reverse_uploaded_variants()
  end

  defp put_variant_body(context, variant, body) do
    case context.storage_adapter.put_public(
           context.bucket,
           variant.key,
           body,
           media_type(variant.container),
           context.region
         ) do
      {:ok, _body} ->
        {:ok, uploaded_variant(context, variant, byte_size(body))}

      {:error, reason} ->
        {:error, {:rendition_upload_failed, variant.size, reason}}
    end
  end

  defp put_variant_files(context, variants, output_paths) do
    variants
    |> Enum.reduce_while({:ok, []}, fn variant, {:ok, acc} ->
      local_path = Map.fetch!(output_paths, variant.size)

      case put_variant_file(context, variant, local_path) do
        {:ok, uploaded} -> {:cont, {:ok, [uploaded | acc]}}
        {:error, reason} -> {:halt, {:error, reason}}
      end
    end)
    |> reverse_uploaded_variants()
  end

  defp put_variant_file(context, variant, local_path) do
    with {:ok, %{size: size}} <- File.stat(local_path),
         {:ok, _} <-
           context.storage_adapter.put_file_public(
             context.bucket,
             variant.key,
             local_path,
             media_type(variant.container),
             context.region
           ) do
      {:ok, uploaded_variant(context, variant, size)}
    else
      {:error, reason} -> {:error, {:rendition_upload_failed, variant.size, reason}}
    end
  end

  defp prepackage_hls_variants(context, variants, output_paths, report_progress? \\ false) do
    Enum.reduce(variants, {%{}, []}, fn variant, {outputs, errors} ->
      case prepackage_hls_variant(context, variant, output_paths, report_progress?) do
        {:ok, output} ->
          {Map.put(outputs, variant.size, output), errors}

        {:error, reason} ->
          {outputs,
           [
             %{"size" => variant.size, "error" => inspect(reason)}
             | errors
           ]}
      end
    end)
  end

  defp prepackage_hls_variant(context, variant, output_paths, report_progress?) do
    input_path = Map.fetch!(output_paths, variant.size)

    MediaPackageHlsVariantStep.package_local_variant(%{
      storage_adapter: context.storage_adapter,
      input_path: input_path,
      bucket: context.bucket,
      embed_hash: context.embed_hash,
      version: context.version,
      codec: "h264",
      size: variant.size,
      resolution: variant.resolution,
      region: context.region,
      tmp_dir: Path.dirname(input_path),
      hls_dir_basename: "hls_#{variant.size}",
      step_id: "hls_h264_#{variant.size}",
      progress: prepackage_hls_progress(context, variant, report_progress?)
    })
  end

  defp prepackage_hls_progress(_context, _variant, false), do: nil
  defp prepackage_hls_progress(%{progress_reporter: nil}, _variant, true), do: nil

  defp prepackage_hls_progress(context, variant, true) do
    %{
      reporter: context.progress_reporter,
      stage: "package_hls",
      step_id: context.step_id,
      codec: "h264",
      size: variant.size,
      container: "hls",
      total_ms: inspect_duration_ms(context.dependency_outputs)
    }
  end

  defp attach_hls_outputs(uploaded_variants, hls_outputs) do
    Enum.map(uploaded_variants, fn variant ->
      case Map.get(hls_outputs, variant["size"]) do
        %{} = hls_output -> Map.put(variant, "hls", hls_output)
        _ -> variant
      end
    end)
  end

  defp put_hls_prepackage_metadata(metadata, hls_outputs, hls_errors) do
    metadata
    |> Map.put("hls_prepackaged_sizes", Map.keys(hls_outputs) |> Enum.sort())
    |> maybe_put_hls_prepackage_errors(Enum.reverse(hls_errors))
  end

  defp maybe_put_hls_prepackage_errors(metadata, []), do: metadata

  defp maybe_put_hls_prepackage_errors(metadata, errors) do
    Map.put(metadata, "hls_prepackage_errors", errors)
  end

  defp prepackage_frame_outputs(%{frame_prepackage_specs: []}, _variants, _output_paths),
    do: {%{}, []}

  defp prepackage_frame_outputs(context, variants, output_paths) do
    Enum.reduce(context.frame_prepackage_specs, {%{}, []}, fn spec, {outputs, errors} ->
      case prepackage_frame_output(context, variants, output_paths, spec) do
        {:ok, output} ->
          {Map.put(outputs, frame_output_key(output["role"], output["codec"]), output), errors}

        {:error, reason} ->
          {outputs,
           [
             %{
               "role" => Map.get(spec, "role"),
               "codec" => Map.get(spec, "codec"),
               "error" => inspect(reason)
             }
             | errors
           ]}
      end
    end)
  end

  defp prepackage_frame_output(context, variants, output_paths, spec) do
    role = Map.fetch!(spec, "role")
    codec = Map.fetch!(spec, "codec")

    with {:ok, input_path, source_size} <- frame_source_path(role, variants, output_paths),
         {:ok, output_path} <- frame_output_path(Path.dirname(input_path), role, codec),
         {:ok, key} <- build_frame_key(context.embed_hash, context.version, role, codec),
         {:ok, ffmpeg_bin} <- StepSupport.find_ffmpeg(),
         {:ok, args} <- build_frame_ffmpeg_args(input_path, output_path, role, codec),
         {ffmpeg_output, 0} <-
           StepSupport.run_media_cmd(ffmpeg_bin, args, timeout_ms: @frame_prepackage_timeout_ms),
         {:ok, %{size: file_size}} <- non_empty_file_stat(output_path),
         {:ok, _} <-
           context.storage_adapter.put_file_public(
             context.bucket,
             key,
             output_path,
             frame_media_type(codec),
             context.region
           ) do
      uri = "s3://#{context.bucket}/#{key}"
      rendition = frame_rendition(role, codec, key, uri, file_size)

      output =
        %{
          "status" => "ok",
          "step_type" => "media.extract_frame",
          "mode" => "prepackaged",
          "step_id" => "#{role}_frame",
          "role" => role,
          "codec" => codec,
          "bucket" => context.bucket,
          "key" => key,
          "uri" => uri,
          "src" => uri,
          "file_size" => file_size,
          "source_step_id" => context.step_id,
          "source_size" => source_size,
          "space_hash" => context.space_hash,
          "embed_hash" => context.embed_hash,
          "version" => StepSupport.normalize_version(context.version),
          "rendition" => rendition,
          "renditions" => [rendition],
          "ffmpeg_output" => truncate(ffmpeg_output, 500)
        }
        |> maybe_add_frame_poster_src(role, uri)

      {:ok, output}
    else
      {:error, reason} ->
        {:error, reason}

      {ffmpeg_output, status} when is_binary(ffmpeg_output) and is_integer(status) ->
        {:error, {:ffmpeg_exit, status, truncate(ffmpeg_output, 1000)}}
    end
  end

  defp frame_source_path(role, variants, output_paths) do
    source_size =
      role
      |> frame_source_size_preferences()
      |> Enum.find(&Map.has_key?(output_paths, &1))
      |> case do
        nil -> variants |> List.first() |> then(&(&1 && &1.size))
        size -> size
      end

    case source_size do
      nil -> {:error, :missing_frame_source}
      size -> {:ok, Map.fetch!(output_paths, size), size}
    end
  end

  defp frame_source_size_preferences("poster"), do: ~w(fhd hd sd qhd uhd)
  defp frame_source_size_preferences(_role), do: ~w(sd hd fhd qhd uhd)

  defp frame_output_path(tmp_dir, role, codec) do
    StepSupport.tmp_file_path(tmp_dir, "prepackaged_#{role}", codec)
  end

  defp build_frame_ffmpeg_args(input_path, output_path, role, codec) do
    with {:ok, codec_name} <- frame_codec_name(codec) do
      case role do
        "poster" ->
          {:ok,
           [
             "-hide_banner",
             "-loglevel",
             "error",
             "-y",
             "-i",
             input_path,
             "-map_metadata",
             "-1",
             "-c:v",
             codec_name,
             "-vf",
             @poster_scale_filter,
             "-frames:v",
             "1",
             "-q:v",
             "6",
             output_path
           ]}

        "thumbnail" ->
          {:ok,
           [
             "-hide_banner",
             "-loglevel",
             "error",
             "-y",
             "-i",
             input_path,
             "-map_metadata",
             "-1",
             "-c:v",
             codec_name,
             "-frames:v",
             "1",
             "-vf",
             RenditionSizing.long_edge_scale_filter(1280),
             output_path
           ]}

        "placeholder" ->
          {:ok,
           [
             "-hide_banner",
             "-loglevel",
             "error",
             "-y",
             "-i",
             input_path,
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

        _role ->
          {:error, {:unsupported_frame_role, role}}
      end
    end
  end

  defp build_frame_key(embed_hash, version, role, codec) do
    filename = "#{role}.#{codec}"

    if StepSupport.normalize_version(version) > 0 do
      {:ok, "#{embed_hash}/v#{StepSupport.normalize_version(version)}/#{filename}"}
    else
      {:ok, "#{embed_hash}/#{filename}"}
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

  defp maybe_add_frame_poster_src(output, "poster", uri),
    do: Map.put(output, "poster_image_src", uri)

  defp maybe_add_frame_poster_src(output, _role, _uri), do: output

  defp put_frame_prepackage_metadata(metadata, frame_outputs, frame_errors) do
    metadata
    |> maybe_put_frame_outputs(frame_outputs)
    |> maybe_put_frame_prepackage_errors(Enum.reverse(frame_errors))
  end

  defp maybe_put_frame_outputs(metadata, frame_outputs) when map_size(frame_outputs) == 0,
    do: metadata

  defp maybe_put_frame_outputs(metadata, frame_outputs) do
    metadata
    |> Map.put("frame_outputs", frame_outputs)
    |> Map.put("frame_prepackaged", frame_outputs |> Map.keys() |> Enum.sort())
  end

  defp maybe_put_frame_prepackage_errors(metadata, []), do: metadata

  defp maybe_put_frame_prepackage_errors(metadata, errors) do
    Map.put(metadata, "frame_prepackage_errors", errors)
  end

  defp frame_prepackage_specs(params) do
    params
    |> Map.get("prepackage_frames", [])
    |> normalize_frame_prepackage_specs()
  end

  defp normalize_frame_prepackage_specs(value) when value in [true, "true", 1, "1"],
    do: @prepackaged_frame_specs

  defp normalize_frame_prepackage_specs(values) when is_list(values) do
    values
    |> Enum.flat_map(&normalize_frame_prepackage_spec/1)
    |> Enum.uniq_by(&frame_output_key(&1["role"], &1["codec"]))
  end

  defp normalize_frame_prepackage_specs(_value), do: []

  defp normalize_frame_prepackage_spec(%{} = spec) do
    role = normalize_frame_role(Map.get(spec, "role", Map.get(spec, :role)))
    codec = normalize_frame_codec(Map.get(spec, "codec", Map.get(spec, :codec, "jpg")))

    if role && codec, do: [%{"role" => role, "codec" => codec}], else: []
  end

  defp normalize_frame_prepackage_spec(role) do
    case normalize_frame_role(role) do
      nil -> []
      role -> [%{"role" => role, "codec" => "jpg"}]
    end
  end

  defp normalize_frame_role(value) when is_binary(value) do
    value = value |> String.trim() |> String.downcase()
    if value in @prepackaged_frame_roles, do: value
  end

  defp normalize_frame_role(value) when is_atom(value),
    do: value |> Atom.to_string() |> normalize_frame_role()

  defp normalize_frame_role(_value), do: nil

  defp normalize_frame_codec(value) when is_binary(value) do
    value = value |> String.trim() |> String.downcase()
    if value in @prepackaged_frame_codecs, do: if(value == "jpeg", do: "jpg", else: value)
  end

  defp normalize_frame_codec(value) when is_atom(value),
    do: value |> Atom.to_string() |> normalize_frame_codec()

  defp normalize_frame_codec(_value), do: nil

  defp frame_output_key(role, codec), do: "#{role}:#{codec}"

  defp frame_codec_name("jpg"), do: {:ok, "mjpeg"}
  defp frame_codec_name("jpeg"), do: {:ok, "mjpeg"}
  defp frame_codec_name(codec), do: {:error, {:unsupported_frame_codec, codec}}

  defp frame_media_type("jpg"), do: "image/jpeg"
  defp frame_media_type("jpeg"), do: "image/jpeg"
  defp frame_media_type(_codec), do: "application/octet-stream"

  defp play_button_image_ref do
    case :code.priv_dir(:mave_core) do
      priv_dir when is_list(priv_dir) ->
        path = Path.join([List.to_string(priv_dir), "static", "images", "play.png"])
        if File.regular?(path), do: path, else: raise("bundled play button image is missing")

      _other ->
        raise "could not resolve the bundled play button image"
    end
  end

  defp non_empty_file_stat(path) do
    case File.stat(path) do
      {:ok, %{size: size} = stat} when size > 0 -> {:ok, stat}
      {:ok, _stat} -> {:error, :empty_frame_output}
      {:error, reason} -> {:error, reason}
    end
  end

  defp reverse_uploaded_variants({:ok, uploaded}), do: {:ok, Enum.reverse(uploaded)}
  defp reverse_uploaded_variants({:error, reason}), do: {:error, reason}

  defp uploaded_variant(context, variant, file_size) do
    uri = "s3://#{context.bucket}/#{variant.key}"

    %{
      "status" => "ok",
      "step_type" => "media.transcode_h264_ladder",
      "step_id" => context.step_id,
      "variant_id" => "h264_#{variant.size}",
      "codec" => "h264",
      "size" => variant.size,
      "container" => variant.container,
      "resolution" => variant.resolution,
      "bucket" => context.bucket,
      "key" => variant.key,
      "uri" => uri,
      "file_size" => file_size,
      "rendition" => rendition(variant, uri, file_size)
    }
  end

  defp output(context, variants, uploaded_variants, actual_mode, mode_meta) do
    renditions = Enum.map(uploaded_variants, & &1["rendition"])
    skipped_variants = Enum.map(context.skipped_sizes, &skipped_variant(context, &1))
    duration = inspect_duration(context.dependency_outputs)
    hls_variant_outputs = hls_variant_outputs(uploaded_variants)

    variant_outputs =
      (uploaded_variants ++ skipped_variants)
      |> Map.new(&{&1["size"], &1})

    %{
      "status" => "ok",
      "step_type" => "media.transcode_h264_ladder",
      "mode" => actual_mode,
      "step_id" => context.step_id,
      "codec" => "h264",
      "container" => context.container,
      "requested_sizes" => context.requested_sizes,
      "sizes" => Enum.map(variants, & &1.size),
      "bucket" => context.bucket,
      "duration" => duration,
      "duration_ms" => duration_ms(duration),
      "variants" => uploaded_variants,
      "skipped_variants" => skipped_variants,
      "variant_outputs" => variant_outputs,
      "hls_variant_outputs" => hls_variant_outputs,
      "rendition" => List.first(renditions),
      "renditions" => renditions
    }
    |> Map.merge(mode_meta)
  end

  defp hls_variant_outputs(uploaded_variants) do
    uploaded_variants
    |> Enum.flat_map(fn
      %{"size" => size, "hls" => %{} = hls_output} -> [{size, hls_output}]
      _variant -> []
    end)
    |> Map.new()
  end

  defp rendition(variant, uri, file_size) do
    %{
      "type" => "video",
      "size" => variant.size,
      "codec" => "h264",
      "container" => variant.container,
      "progress" => 100.0,
      "rendition_key" => variant.key,
      "src" => uri,
      "file_size" => file_size
    }
  end

  defp skipped_variant(context, size) do
    %{
      "status" => "skipped",
      "step_type" => "media.transcode_h264_ladder",
      "step_id" => context.step_id,
      "variant_id" => "h264_#{size}",
      "codec" => "h264",
      "size" => size,
      "container" => context.container,
      "bucket" => context.bucket,
      "reason" => "source_resolution_below_variant",
      "source_width" => inspect_dimension(context.dependency_outputs, "width"),
      "source_height" => inspect_dimension(context.dependency_outputs, "height"),
      "source_long_edge" => inspect_long_edge(context.dependency_outputs)
    }
  end

  defp artifacts(uploaded_variants, context, space_hash, embed_hash) do
    Enum.map(uploaded_variants, fn variant ->
      %{
        name: "video_h264_#{variant["size"]}",
        uri: variant["uri"],
        media_type: media_type(context.container),
        size_bytes: variant["file_size"],
        metadata: %{
          "type" => "video",
          "codec" => "h264",
          "size" => variant["size"],
          "container" => context.container,
          "space_hash" => space_hash,
          "embed_hash" => embed_hash,
          "version" => StepSupport.normalize_version(context.version)
        }
      }
    end)
  end

  defp build_variants(embed_hash, version, sizes, container, keyframe_interval) do
    sizes
    |> Enum.reduce_while({:ok, []}, fn size, {:ok, acc} ->
      case build_variant(embed_hash, version, size, container, keyframe_interval) do
        {:ok, variant} -> {:cont, {:ok, [variant | acc]}}
        {:error, reason} -> {:halt, {:error, reason}}
      end
    end)
    |> case do
      {:ok, variants} -> {:ok, Enum.reverse(variants)}
      {:error, reason} -> {:error, reason}
    end
  end

  defp build_variant(embed_hash, version, size, container, keyframe_interval) do
    with {:ok, profile} <- profile_for_size(size),
         {:ok, key} <- build_key(embed_hash, version, size, container, keyframe_interval) do
      {:ok,
       %{
         size: size,
         container: container,
         key: key,
         profile: profile,
         resolution: nil,
         long_edge: nil
       }}
    end
  end

  defp attach_variant_resolutions(variants, dependency_outputs) do
    source_metadata = inspect_media_output(dependency_outputs)

    Enum.map(variants, fn variant ->
      variant
      |> attach_variant_long_edge(source_metadata)
      |> attach_variant_resolution(source_metadata)
    end)
  end

  defp attach_variant_long_edge(variant, source_metadata) do
    case RenditionSizing.capped_target_long_edge(variant.size, source_metadata) do
      {:ok, long_edge} -> %{variant | long_edge: long_edge}
      _other -> variant
    end
  end

  defp attach_variant_resolution(variant, source_metadata) do
    case RenditionSizing.scaled_resolution(variant.size, source_metadata) do
      {:ok, resolution} -> %{variant | resolution: resolution}
      _other -> variant
    end
  end

  defp build_key(embed_hash, version, size, container, keyframe_interval) do
    suffix = if keyframe_interval == 2, do: "_clip_keyframes", else: ""
    filename = "h264_#{size}#{suffix}.#{container}"

    key =
      if StepSupport.normalize_version(version) > 0 do
        "#{embed_hash}/v#{StepSupport.normalize_version(version)}/#{filename}"
      else
        "#{embed_hash}/#{filename}"
      end

    {:ok, key}
  end

  defp profile_for_size(size) do
    case Map.fetch(@profiles, size) do
      {:ok, profile} -> {:ok, profile}
      :error -> {:error, {:unsupported_size, size}}
    end
  end

  defp build_output_paths(tmp_dir, variants) do
    variants
    |> Enum.reduce_while({:ok, %{}}, fn variant, {:ok, acc} ->
      case StepSupport.tmp_file_path(tmp_dir, "h264_#{variant.size}", variant.container) do
        {:ok, path} -> {:cont, {:ok, Map.put(acc, variant.size, path)}}
        {:error, reason} -> {:halt, {:error, reason}}
      end
    end)
  end

  defp validate_variant_outputs(output_paths) do
    output_paths
    |> Map.values()
    |> Enum.reduce_while(:ok, fn output_path, :ok ->
      case StepSupport.validate_media_file(output_path, :video) do
        :ok -> {:cont, :ok}
        {:error, reason} -> {:halt, {:error, reason}}
      end
    end)
  end

  defp configured_sizes(params) do
    params
    |> Map.get("sizes", Map.get(params, "variants", Map.get(params, "size")))
    |> normalize_sizes()
  end

  defp normalize_sizes(nil), do: @default_sizes

  defp normalize_sizes(value) when is_binary(value) do
    value
    |> String.split(",", trim: true)
    |> Enum.map(&String.trim/1)
    |> Enum.reject(&(&1 == ""))
    |> normalize_sizes()
  end

  defp normalize_sizes(values) when is_list(values) do
    values
    |> Enum.map(&normalize_size/1)
    |> Enum.reject(&is_nil/1)
    |> Enum.uniq()
    |> case do
      [] -> @default_sizes
      sizes -> sizes
    end
  end

  defp normalize_sizes(value), do: normalize_sizes([value])

  defp normalize_size(%{"size" => size}), do: normalize_size(size)
  defp normalize_size(%{size: size}), do: normalize_size(size)
  defp normalize_size(size) when is_atom(size), do: Atom.to_string(size)

  defp normalize_size(size) when is_binary(size) do
    size
    |> String.trim()
    |> String.downcase()
  end

  defp normalize_size(_size), do: nil

  defp active_sizes(requested_sizes, dependency_outputs, params) do
    if conditional_sizes?(params) do
      require_source_resolution? = require_source_resolution?(params)

      requested_sizes
      |> source_resolution_filtered_sizes(
        inspect_media_output(dependency_outputs),
        require_source_resolution?
      )
      |> case do
        [] when require_source_resolution? -> []
        [] -> Enum.take(requested_sizes, 1)
        sizes -> sizes
      end
    else
      requested_sizes
    end
  end

  defp conditional_sizes?(params) do
    params
    |> Map.get("conditional_sizes", true)
    |> truthy?()
  end

  defp require_source_resolution?(params) do
    params
    |> Map.get("require_source_resolution", false)
    |> truthy?()
  end

  defp source_resolution_filtered_sizes(
         requested_sizes,
         source_metadata,
         require_source_resolution?
       ) do
    RenditionSizing.filter_sizes(requested_sizes, source_metadata, require_source_resolution?)
  end

  defp ladder_audio_strategy(dependency_outputs) do
    dependency_outputs
    |> inspect_media_output()
    |> unsafe_audio_streams?()
    |> case do
      true -> :video_only
      false -> :include
    end
  end

  defp unsafe_audio_streams?(inspect_output) when is_map(inspect_output) do
    unsafe_audio_codec_field?(inspect_output) or
      inspect_output
      |> map_get("streams", [])
      |> audio_streams()
      |> Enum.any?(&unsafe_audio_stream?/1)
  end

  defp unsafe_audio_streams?(_inspect_output), do: false

  defp unsafe_audio_codec_field?(inspect_output) do
    case map_get(inspect_output, "audio_codec") do
      nil -> false
      value -> unsafe_audio_codec?(value)
    end
  end

  defp audio_streams(streams) when is_list(streams) do
    Enum.filter(streams, &(map_get(&1, "codec_type") == "audio"))
  end

  defp audio_streams(_streams), do: []

  defp unsafe_audio_stream?(stream) do
    unsafe_audio_codec?(map_get(stream, "codec_name")) or
      unsafe_audio_tag?(map_get(stream, "codec_tag_string")) or
      unsafe_audio_tag?(map_get(stream, "codec_tag"))
  end

  defp unsafe_audio_codec?(value) do
    value
    |> normalize_string()
    |> case do
      codec when codec in ["", "none", "unknown"] -> true
      _codec -> false
    end
  end

  defp unsafe_audio_tag?(nil), do: false

  defp unsafe_audio_tag?(value) do
    value
    |> normalize_string()
    |> case do
      tag when tag in ["apac", "0x63617061"] -> true
      _tag -> false
    end
  end

  defp inspect_media_output(dependency_outputs) do
    dependency_outputs
    |> map_get("inspect_media", %{})
  end

  defp inspect_dimension(dependency_outputs, dimension) do
    dependency_outputs
    |> inspect_media_output()
    |> map_get(dimension)
    |> positive_integer_value()
  end

  defp inspect_long_edge(dependency_outputs) do
    dependency_outputs
    |> inspect_media_output()
    |> RenditionSizing.source_long_edge()
  end

  defp positive_integer_value(value) when is_integer(value) and value > 0, do: value

  defp positive_integer_value(value) when is_binary(value) do
    case Integer.parse(value) do
      {integer, _rest} when integer > 0 -> integer
      _ -> nil
    end
  end

  defp positive_integer_value(_value), do: nil

  defp truthy?(value), do: value in [true, "true", "1", 1]

  defp encoder_settings(params, run_input) do
    app_config = Application.get_env(:mave_core, :media_h264_ladder_encoder, [])

    %{
      preset:
        run_input
        |> Map.get("media_transcode_h264_ladder_preset", Map.get(params, "preset"))
        |> normalize_x264_preset(encoder_config_value(app_config, :preset)),
      tune:
        run_input
        |> Map.get("media_transcode_h264_ladder_tune", Map.get(params, "tune"))
        |> normalize_x264_tune(encoder_config_value(app_config, :tune))
    }
  end

  defp encoder_config_value(config, key) when is_list(config), do: Keyword.get(config, key)

  defp encoder_config_value(config, key) when is_map(config) do
    Map.get(config, key) || Map.get(config, Atom.to_string(key))
  end

  defp encoder_config_value(_config, _key), do: nil

  defp encoder_metadata(%{preset: preset, tune: nil}), do: %{"preset" => preset}
  defp encoder_metadata(%{preset: preset, tune: tune}), do: %{"preset" => preset, "tune" => tune}

  defp production_encoder_metadata do
    %{
      "codec" => "h264",
      "preset" => "veryfast",
      "rate_control" => "abr",
      "profile" => ProductionEncodingProfile.name()
    }
  end

  defp normalize_x264_preset(value, fallback) do
    case normalize_x264_preset_value(value) do
      nil -> normalize_x264_preset_value(fallback) || @default_x264_preset
      preset -> preset
    end
  end

  defp normalize_x264_preset_value(value) do
    case normalize_string(value) do
      preset when preset in @x264_presets -> preset
      _other -> nil
    end
  end

  defp normalize_x264_tune(value, fallback) do
    case normalize_x264_tune_value(value) do
      :unset -> normalize_x264_tune_value(fallback) |> normalize_x264_tune_fallback()
      tune -> tune
    end
  end

  defp normalize_x264_tune_value(value) do
    case normalize_string(value) do
      tune when tune in @x264_tunes -> tune
      tune when tune in ["", "none", "false", "off"] -> nil
      _other -> :unset
    end
  end

  defp normalize_x264_tune_fallback(:unset), do: nil
  defp normalize_x264_tune_fallback(tune), do: tune

  defp normalize_string(value) when is_binary(value),
    do: value |> String.trim() |> String.downcase()

  defp normalize_string(value) when is_atom(value),
    do: value |> Atom.to_string() |> normalize_string()

  defp normalize_string(value) when is_boolean(value),
    do: value |> to_string() |> normalize_string()

  defp normalize_string(_value), do: nil

  defp ffmpeg_progress(%{progress_reporter: nil}, _variants), do: nil

  defp ffmpeg_progress(context, variants) do
    %{
      reporter: context.progress_reporter,
      stage: "transcode",
      step_id: context.step_id,
      codec: "h264",
      size: "ladder",
      container: context.container,
      variants: Enum.map(variants, & &1.size),
      preset: context.encoder_settings.preset,
      tune: context.encoder_settings.tune,
      total_ms: inspect_duration_ms(context.dependency_outputs)
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
      "variants" => progress.variants,
      "preset" => progress.preset,
      "tune" => progress.tune,
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

  defp inspect_duration_seconds(dependency_outputs) do
    case inspect_duration(dependency_outputs) do
      value when is_integer(value) and value > 0 ->
        value * 1.0

      value when is_float(value) and value > 0 ->
        value

      value when is_binary(value) ->
        case Float.parse(value) do
          {parsed, _rest} when parsed > 0 -> parsed
          _other -> nil
        end

      _other ->
        nil
    end
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

  defp video_command_timeout_ms do
    Application.get_env(:mave_core, :media_transcode_video_command_timeout_ms)
  end

  defp unavailable_output(step_id, sizes, container, reason) do
    %{
      "status" => "unavailable",
      "step_type" => "media.transcode_h264_ladder",
      "mode" => "failed",
      "step_id" => step_id,
      "codec" => "h264",
      "sizes" => sizes,
      "container" => container,
      "error" => inspect(reason)
    }
  end

  defp skipped_output(step_id, sizes, container, reason) do
    %{
      "status" => "skipped",
      "step_type" => "media.transcode_h264_ladder",
      "mode" => "skipped",
      "step_id" => step_id,
      "codec" => "h264",
      "sizes" => sizes,
      "container" => container,
      "reason" => reason
    }
  end

  defp media_type("mp4"), do: "video/mp4"
  defp media_type("mkv"), do: "video/x-matroska"
  defp media_type("webm"), do: "video/webm"
  defp media_type(_), do: "application/octet-stream"

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
  defp map_get(map, key) when is_map(map), do: map_get(map, key, nil)
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
