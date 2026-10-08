defmodule MaveCore.Flow.Steps.MediaTranscodeAudioStep do
  @moduledoc """
  Produces audio track artifacts for the flow.

  Modes:
  - `auto` (default): FFmpeg for normal sources; copy-mode only for inline `source_body`
  - `copy`: compatibility mode for inline `source_body`
  - `ffmpeg`: always use FFmpeg extraction/transcode
  """
  @behaviour MaveCore.Flow.Step

  alias MaveCore.EncodingBooster
  alias MaveCore.Flow.Steps.Support, as: StepSupport
  alias MaveCore.Media.{Signature, Storage}

  @supported_modes ~w(auto copy ffmpeg)

  @impl true
  def run(step_definition, context) do
    step_context = build_step_context(step_definition, context)

    track_specs =
      audio_track_specs(
        step_context.inspect_output,
        step_context.params,
        step_context.label,
        step_context.language,
        step_context.default_track
      )

    execute_transcode_step(step_context, track_specs)
  end

  defp build_step_context(step_definition, context) do
    run_input = Map.get(context, :run_input, %{})
    dependency_outputs = Map.get(context, :dependency_outputs, %{})
    source = Map.get(dependency_outputs, "source", %{})
    inspect_output = Map.get(dependency_outputs, "inspect_media", %{})
    params = Map.get(step_definition, "params", %{})
    step_id = Map.get(step_definition, "id", "transcode_audio")

    source_url =
      Map.get(source, "source_url") || Map.get(run_input, "input_url") ||
        Map.get(run_input, "source_url")

    space_hash = Map.get(source, "space_hash") || Map.get(run_input, "space_hash")
    embed_hash = Map.get(source, "embed_hash") || Map.get(run_input, "embed_hash")
    version = Map.get(source, "version") || Map.get(run_input, "version", 0)
    region = Map.get(run_input, "region")
    codec = normalize_param(Map.get(params, "codec"), "mp3")
    container = normalize_param(Map.get(params, "container"), container_for_codec(codec))
    label = normalize_param(Map.get(params, "label"), "Original")
    language = normalize_param(Map.get(params, "language"), nil)
    default_track = normalize_boolean(Map.get(params, "default"), true)
    mode = StepSupport.normalize_mode(run_input, "media_transcode_audio_mode", @supported_modes)
    strict? = StepSupport.strict_enabled?(params, run_input, "media_transcode_audio_strict")
    storage_adapter = Application.get_env(:mave_core, :flow_storage_adapter, Storage)
    bucket = Storage.bucket_for_space(space_hash, region)

    %{
      inspect_output: inspect_output,
      params: params,
      label: label,
      language: language,
      default_track: default_track,
      strict?: strict?,
      transcode_context: %{
        run_input: run_input,
        dependency_outputs: dependency_outputs,
        source_url: source_url,
        codec: codec,
        container: container,
        storage_adapter: storage_adapter,
        bucket: bucket,
        embed_hash: embed_hash,
        version: version,
        region: region,
        step_id: step_id,
        space_hash: space_hash,
        mode: mode,
        progress_reporter: Map.get(context, :progress_reporter),
        encoding_booster_dispatch: Map.get(context, :encoding_booster_dispatch),
        encoding_booster_fallback_code: Map.get(context, :encoding_booster_fallback_code)
      }
    }
  end

  defp execute_transcode_step(step_context, track_specs) do
    cond do
      inspect_reports_no_audio?(step_context.inspect_output) ->
        skipped_step_result(step_context.transcode_context, "no audio stream")

      track_specs == [] ->
        skipped_step_result(step_context.transcode_context, "no decodable audio stream")

      true ->
        step_context
        |> validate_transcode_context()
        |> run_transcode_tracks(track_specs, step_context)
    end
  end

  defp validate_transcode_context(step_context) do
    transcode_context = step_context.transcode_context

    with {:ok, space_hash} <-
           StepSupport.require_binary(transcode_context.space_hash, :space_hash),
         {:ok, embed_hash} <-
           StepSupport.require_binary(transcode_context.embed_hash, :embed_hash),
         {:ok, source_url} <-
           StepSupport.require_binary(transcode_context.source_url, :source_url) do
      {:ok,
       %{
         transcode_context
         | source_url: source_url,
           embed_hash: embed_hash,
           space_hash: space_hash
       }}
    end
  end

  defp run_transcode_tracks({:ok, transcode_context}, track_specs, step_context) do
    track_specs
    |> transcode_tracks(transcode_context)
    |> handle_transcode_result(step_context, transcode_context)
  end

  defp run_transcode_tracks({:error, reason}, _track_specs, step_context) do
    handle_transcode_error(reason, step_context)
  end

  defp handle_transcode_result({:ok, [%{} | _] = results}, _step_context, transcode_context) do
    {:ok, build_transcode_output(results, transcode_context),
     collect_transcode_artifacts(results)}
  end

  defp handle_transcode_result({:error, :no_audio_stream}, _step_context, transcode_context) do
    skipped_step_result(transcode_context, "no audio stream")
  end

  defp handle_transcode_result(
         {:error, {:encoding_booster_fallback_required, _code, _reason} = reason},
         _step_context,
         _transcode_context
       ) do
    {:error, reason}
  end

  defp handle_transcode_result({:error, reason}, step_context, _transcode_context) do
    handle_transcode_error(reason, step_context)
  end

  defp handle_transcode_error(reason, %{strict?: true}) do
    {:error, {:media_transcode_audio_failed, reason}}
  end

  defp handle_transcode_error(reason, %{transcode_context: transcode_context}) do
    {:ok,
     unavailable_output(
       transcode_context.step_id,
       transcode_context.codec,
       transcode_context.container,
       reason
     ), []}
  end

  defp skipped_step_result(transcode_context, reason) do
    {:ok,
     skipped_output(
       transcode_context.step_id,
       transcode_context.codec,
       transcode_context.container,
       reason
     ), []}
  end

  defp transcode_tracks(track_specs, transcode_context) do
    track_specs
    |> Enum.reduce_while({:ok, []}, fn track_spec, {:ok, acc} ->
      case transcode_track(track_spec, transcode_context) do
        {:ok, result} ->
          {:cont, {:ok, acc ++ [result]}}

        {:error, reason} ->
          {:halt, {:error, reason}}
      end
    end)
  end

  defp transcode_track(track_spec, transcode_context) do
    progress =
      StepSupport.ffmpeg_progress(transcode_context.progress_reporter, %{
        stage: "transcode",
        step_id: transcode_context.step_id,
        codec: transcode_context.codec,
        container: transcode_context.container,
        total_ms: StepSupport.inspect_duration_ms(transcode_context.dependency_outputs)
      })

    with {:ok, key} <-
           build_key(
             transcode_context.embed_hash,
             transcode_context.version,
             transcode_context.codec,
             transcode_context.container,
             track_spec
           ),
         {:ok, stored_audio, actual_mode, mode_meta} <-
           build_and_put_audio(transcode_context, track_spec, key, progress) do
      {:ok,
       build_transcoded_track(
         track_spec,
         key,
         stored_audio.uri,
         stored_audio.file_size,
         actual_mode,
         mode_meta,
         transcode_context
       )}
    end
  end

  defp build_transcoded_track(
         track_spec,
         key,
         uri,
         file_size,
         actual_mode,
         mode_meta,
         transcode_context
       ) do
    filename = Path.basename(key)

    %{
      "key" => key,
      "uri" => uri,
      "file_size" => file_size,
      "mode" => actual_mode,
      "mode_meta" => mode_meta,
      "audio_track" =>
        build_transcoded_audio_track(
          track_spec,
          uri,
          filename,
          file_size,
          transcode_context.codec
        ),
      "rendition" =>
        build_transcoded_rendition(
          key,
          uri,
          file_size,
          transcode_context.codec,
          transcode_context.container
        ),
      "artifacts" => [
        build_transcoded_artifact(
          track_spec,
          uri,
          filename,
          file_size,
          transcode_context
        )
      ]
    }
  end

  defp build_and_put_audio(
         %{encoding_booster_dispatch: :direct} = transcode_context,
         track_spec,
         key,
         progress
       ) do
    transcode_audio_with_booster(transcode_context, track_spec, key, progress)
  end

  defp build_and_put_audio(transcode_context, track_spec, key, progress) do
    with {:ok, audio_body, actual_mode, mode_meta} <-
           build_audio_body(
             transcode_context.mode,
             transcode_context.run_input,
             transcode_context.source_url,
             transcode_context.dependency_outputs,
             transcode_context.codec,
             transcode_context.container,
             track_spec,
             progress
           ),
         {:ok, uri} <-
           put_audio(
             transcode_context.storage_adapter,
             transcode_context.bucket,
             key,
             audio_body,
             transcode_context.container,
             transcode_context.region
           ) do
      mode_meta =
        maybe_put_fallback(
          mode_meta,
          "encoding_booster_fallback",
          transcode_context.encoding_booster_fallback_code
        )

      {:ok, %{uri: uri, file_size: byte_size(audio_body)}, actual_mode, mode_meta}
    end
  end

  defp transcode_audio_with_booster(transcode_context, track_spec, key, _progress) do
    with {:ok, input_url} <-
           StepSupport.encoding_booster_input_url(
             transcode_context.run_input,
             transcode_context.source_url,
             transcode_context.dependency_outputs,
             prefer_source_storage: true
           ),
         {:ok, session} <-
           transcode_context.storage_adapter.start_presigned_multipart_upload(
             transcode_context.bucket,
             key,
             transcode_context.region,
             media_type(transcode_context.container),
             max_bytes: estimated_audio_output_bytes(transcode_context)
           ) do
      upload_audio_with_booster(transcode_context, track_spec, key, input_url, session)
    else
      {:error, reason} -> booster_error(reason)
    end
  end

  defp upload_audio_with_booster(transcode_context, track_spec, key, input_url, session) do
    options =
      [
        operation: "audio",
        audio_codec: transcode_context.codec,
        audio_stream_index: Map.get(track_spec, "stream_selector", 0),
        audio_bitrate: audio_bitrate(transcode_context.codec),
        on_chunk: booster_progress_callback(transcode_context)
      ]
      |> maybe_add_encoding_booster_referer(input_url)

    case encoding_booster_adapter().encode_to_storage(input_url, session.payload, options) do
      {:ok, timing} ->
        verify_booster_audio(transcode_context, key, timing)

      {:error, reason} ->
        _ = transcode_context.storage_adapter.abort_presigned_multipart_upload(session)
        booster_error(reason)
    end
  end

  defp verify_booster_audio(transcode_context, key, timing) do
    case transcode_context.storage_adapter.object_info(
           transcode_context.bucket,
           key,
           transcode_context.region
         ) do
      {:ok, %{size_bytes: size_bytes}} when is_integer(size_bytes) and size_bytes > 0 ->
        verify_booster_audio_content(transcode_context, key, timing, size_bytes)

      {:error, reason} ->
        booster_error({:audio_upload_verification_failed, reason})

      _other ->
        booster_error({:audio_upload_verification_failed, :empty_object})
    end
  end

  defp verify_booster_audio_content(transcode_context, key, timing, size_bytes) do
    with :ok <- validate_booster_audio_timing(timing),
         {:ok, prefix} <-
           transcode_context.storage_adapter.get_prefix(
             transcode_context.bucket,
             key,
             transcode_context.region,
             Signature.audio_output_probe_bytes_limit()
           ),
         :ok <- Signature.validate_audio_output(prefix, transcode_context.container) do
      report_booster_completed(transcode_context, timing, size_bytes)

      metadata =
        %{
          "encoding_booster" => true,
          "encoding_booster_elapsed_ms" => Map.get(timing, :elapsed_ms, 0)
        }
        |> maybe_put_booster_instance(timing)

      {:ok, %{uri: "s3://#{transcode_context.bucket}/#{key}", file_size: size_bytes},
       "encoding_booster", metadata}
    else
      {:error, reason} -> reject_booster_audio(transcode_context, key, reason)
    end
  end

  defp validate_booster_audio_timing(timing) when is_map(timing) do
    case Map.fetch(timing, :out_time_ms) do
      {:ok, out_time_ms} when is_integer(out_time_ms) and out_time_ms > 0 -> :ok
      {:ok, _out_time_ms} -> {:error, :missing_audio_frames}
      :error -> :ok
    end
  end

  defp validate_booster_audio_timing(_timing), do: :ok

  defp reject_booster_audio(transcode_context, key, reason) do
    _ =
      transcode_context.storage_adapter.delete_object(
        transcode_context.bucket,
        key,
        transcode_context.region
      )

    booster_error({:audio_upload_verification_failed, reason})
  end

  defp booster_error(:encoding_booster_busy), do: {:error, :encoding_booster_busy}

  defp booster_error(reason) do
    if EncodingBooster.fallback_enabled?() do
      {:error, {:encoding_booster_fallback_required, encoding_booster_error_code(reason), reason}}
    else
      {:error, reason}
    end
  end

  defp booster_progress_callback(transcode_context) do
    fn bytes ->
      StepSupport.report_progress(transcode_context.progress_reporter, %{
        "source" => "encoding_booster",
        "executor" => "encoding_booster",
        "status" => "encoding",
        "stage" => "transcode",
        "step_id" => transcode_context.step_id,
        "codec" => transcode_context.codec,
        "container" => transcode_context.container,
        "total_size_bytes" => bytes
      })
    end
  end

  defp report_booster_completed(transcode_context, timing, size_bytes) do
    total_ms = StepSupport.inspect_duration_ms(transcode_context.dependency_outputs)
    ffmpeg_elapsed_ms = Map.get(timing, :ffmpeg_elapsed_ms) || Map.get(timing, :elapsed_ms)

    StepSupport.report_progress(transcode_context.progress_reporter, %{
      "source" => "ffmpeg",
      "executor" => "encoding_booster",
      "status" => "completed",
      "stage" => "transcode",
      "step_id" => transcode_context.step_id,
      "codec" => transcode_context.codec,
      "container" => transcode_context.container,
      "percent" => 100.0,
      "total_ms" => total_ms,
      "ffmpeg_elapsed_ms" => ffmpeg_elapsed_ms,
      "speed_x" => derived_speed(total_ms, ffmpeg_elapsed_ms),
      "total_size_bytes" => size_bytes,
      "force" => true
    })
  end

  defp estimated_audio_output_bytes(transcode_context) do
    duration_ms = StepSupport.inspect_duration_ms(transcode_context.dependency_outputs) || 0
    bitrate = if transcode_context.codec == "wav", do: 1_536_000, else: 128_000
    round(duration_ms / 1_000 * bitrate / 8 * 1.2) + 8 * 1024 * 1024
  end

  defp audio_bitrate("opus"), do: "96k"
  defp audio_bitrate(_codec), do: "128k"

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

  defp maybe_put_booster_instance(metadata, %{instance_id: instance_id})
       when is_binary(instance_id),
       do: Map.put(metadata, "encoding_booster_instances", [instance_id])

  defp maybe_put_booster_instance(metadata, _timing), do: metadata

  defp maybe_put_fallback(metadata, _key, nil), do: metadata
  defp maybe_put_fallback(metadata, key, value), do: Map.put(metadata, key, value)

  defp encoding_booster_error_code(:encoding_booster_busy), do: "busy"
  defp encoding_booster_error_code({:encoding_booster_http_status, status}), do: "http_#{status}"

  defp encoding_booster_error_code({:audio_upload_verification_failed, _reason}),
    do: "invalid_output"

  defp encoding_booster_error_code(_reason), do: "request_failed"

  defp build_transcoded_audio_track(track_spec, uri, filename, file_size, codec) do
    %{
      "id" => track_spec["id"],
      "label" => track_spec["label"],
      "language" => track_spec["language"],
      "default" => track_spec["default"],
      "codec" => codec,
      "file_size" => file_size,
      "filename" => filename,
      "path" => uri,
      "src" => uri
    }
  end

  defp build_transcoded_rendition(key, uri, file_size, codec, container) do
    %{
      "type" => "audio",
      "size" => nil,
      "codec" => codec,
      "container" => container,
      "progress" => 100.0,
      "rendition_key" => key,
      "src" => uri,
      "file_size" => file_size
    }
  end

  defp build_transcoded_artifact(track_spec, uri, filename, file_size, transcode_context) do
    %{
      name: artifact_name(track_spec["id"], transcode_context.codec),
      uri: uri,
      media_type: media_type(transcode_context.container),
      size_bytes: file_size,
      metadata: %{
        "type" => "audio",
        "codec" => transcode_context.codec,
        "container" => transcode_context.container,
        "space_hash" => transcode_context.space_hash,
        "embed_hash" => transcode_context.embed_hash,
        "version" => StepSupport.normalize_version(transcode_context.version),
        "filename" => filename,
        "track_id" => track_spec["id"],
        "step_type" => transcode_context.step_id
      }
    }
  end

  defp build_transcode_output(results, transcode_context) do
    primary = Enum.find(results, &get_in(&1, ["audio_track", "default"])) || hd(results)

    %{
      "status" => "ok",
      "step_type" => "media.transcode_audio",
      "mode" => primary["mode"],
      "step_id" => transcode_context.step_id,
      "codec" => transcode_context.codec,
      "container" => transcode_context.container,
      "bucket" => transcode_context.bucket,
      "key" => primary["key"],
      "uri" => primary["uri"],
      "file_size" => primary["file_size"],
      "audio_track" => primary["audio_track"],
      "audio_tracks" => Enum.map(results, & &1["audio_track"]),
      "rendition" => primary["rendition"],
      "renditions" => Enum.map(results, & &1["rendition"])
    }
    |> Map.merge(primary["mode_meta"] || %{})
  end

  defp collect_transcode_artifacts(results) do
    Enum.flat_map(results, & &1["artifacts"])
  end

  defp audio_track_specs(
         inspect_output,
         params,
         fallback_label,
         fallback_language,
         fallback_default
       ) do
    streams =
      inspect_output
      |> map_get("streams", [])
      |> Enum.filter(fn stream -> map_get(stream, "codec_type") == "audio" end)

    stream_entries = Enum.with_index(streams)
    decodable_stream_entries = Enum.reject(stream_entries, &undecodable_audio_stream?/1)

    cond do
      streams == [] and undecodable_audio_codec?(map_get(inspect_output, "audio_codec")) ->
        []

      streams == [] ->
        [fallback_audio_track_spec(params, fallback_label, fallback_language, fallback_default)]

      decodable_stream_entries == [] ->
        []

      true ->
        default_index = default_audio_stream_index(decodable_stream_entries)

        decodable_stream_entries
        |> Enum.map(&build_audio_track_spec(&1, default_index, fallback_label, fallback_language))
        |> Enum.sort_by(&default_audio_track_sort_key/1)
    end
  end

  defp default_audio_stream_index(stream_entries) do
    stream_entries
    |> Enum.find_value(fn {stream, selector} ->
      if default_stream?(stream), do: selector
    end)
    |> case do
      nil ->
        stream_entries
        |> List.first()
        |> elem(1)

      selector ->
        selector
    end
  end

  defp undecodable_audio_stream?({stream, _selector}) do
    undecodable_audio_codec?(map_get(stream, "codec_name")) or
      undecodable_audio_tag?(map_get(stream, "codec_tag_string")) or
      undecodable_audio_tag?(map_get(stream, "codec_tag"))
  end

  defp undecodable_audio_codec?(nil), do: false

  defp undecodable_audio_codec?(value) do
    value
    |> normalize_param("")
    |> String.trim()
    |> String.downcase()
    |> case do
      codec when codec in ["", "none", "unknown"] -> true
      _codec -> false
    end
  end

  defp undecodable_audio_tag?(nil), do: false

  defp undecodable_audio_tag?(value) do
    value
    |> normalize_param("")
    |> String.trim()
    |> String.downcase()
    |> case do
      tag when tag in ["apac", "0x63617061"] -> true
      _tag -> false
    end
  end

  defp fallback_audio_track_spec(params, fallback_label, fallback_language, fallback_default) do
    %{
      "id" => Map.get(params, "track_id") || "default",
      "label" => fallback_label,
      "language" => fallback_language,
      "default" => fallback_default,
      "stream_selector" => 0,
      "default_filename" => true
    }
  end

  defp build_audio_track_spec(
         {stream, selector},
         default_index,
         fallback_label,
         fallback_language
       ) do
    default? = selector == default_index

    %{
      "id" => audio_track_id(default?, selector),
      "label" => stream_label(stream, selector, default?, fallback_label),
      "language" => stream_language(stream, fallback_language),
      "default" => default?,
      "stream_selector" => selector,
      "default_filename" => default?
    }
  end

  defp audio_track_id(true, _selector), do: "default"
  defp audio_track_id(false, selector), do: "track_#{selector + 1}"

  defp default_audio_track_sort_key(%{"default" => true}), do: 0
  defp default_audio_track_sort_key(_spec), do: 1

  defp build_audio_body(
         "copy",
         run_input,
         source_url,
         dependency_outputs,
         _codec,
         _container,
         _track_spec,
         _progress
       ) do
    with {:ok, source_body} <-
           StepSupport.resolve_source_body(run_input, source_url, dependency_outputs) do
      {:ok, source_body, "copy", %{}}
    end
  end

  defp build_audio_body(
         "ffmpeg",
         run_input,
         source_url,
         dependency_outputs,
         codec,
         container,
         track_spec,
         progress
       ) do
    transcode_with_ffmpeg(
      run_input,
      source_url,
      dependency_outputs,
      codec,
      container,
      Map.get(track_spec, "stream_selector", 0),
      progress
    )
  end

  defp build_audio_body(
         "auto",
         run_input,
         source_url,
         dependency_outputs,
         codec,
         container,
         track_spec,
         progress
       ) do
    if Map.has_key?(run_input, "source_body") do
      build_audio_body(
        "copy",
        run_input,
        source_url,
        dependency_outputs,
        codec,
        container,
        track_spec,
        progress
      )
    else
      transcode_with_ffmpeg(
        run_input,
        source_url,
        dependency_outputs,
        codec,
        container,
        Map.get(track_spec, "stream_selector", 0),
        progress
      )
    end
  end

  defp transcode_with_ffmpeg(
         run_input,
         source_url,
         dependency_outputs,
         codec,
         container,
         stream_selector,
         progress
       ) do
    StepSupport.with_temp_dir("transcode_audio", fn tmp_dir ->
      with {:ok, output_path} <- build_output_path(tmp_dir, container),
           {:ok, ffmpeg_output, fallback?} <-
             StepSupport.run_ffmpeg_with_storage_fallback(
               tmp_dir,
               run_input,
               source_url,
               dependency_outputs,
               &build_ffmpeg_args(&1, output_path, codec, stream_selector),
               validate_output: fn -> StepSupport.validate_media_file(output_path, :audio) end,
               progress: progress
             ),
           {:ok, audio_body} <- StepSupport.read_tmp_file(output_path) do
        {:ok, audio_body, "ffmpeg",
         %{"ffmpeg_output" => truncate(ffmpeg_output, 500)}
         |> Map.merge(StepSupport.ffmpeg_fallback_metadata(fallback?))}
      else
        {:error, {ffmpeg_output, status}} when is_binary(ffmpeg_output) and is_integer(status) ->
          ffmpeg_failure(ffmpeg_output, status)

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

  defp build_ffmpeg_args(input_ref, output_path, codec, stream_selector) do
    with {:ok, codec_args} <- codec_args(codec) do
      args =
        [
          "-hide_banner",
          "-loglevel",
          "error",
          "-y",
          "-i",
          input_ref,
          "-map_metadata",
          "-1",
          "-map",
          "0:a:#{stream_selector}"
        ]
        |> Kernel.++(codec_args)
        |> Kernel.++([output_path])

      {:ok, args}
    end
  end

  defp ffmpeg_failure(ffmpeg_output, status) do
    if no_audio_stream_error?(ffmpeg_output) do
      {:error, :no_audio_stream}
    else
      {:error, {:ffmpeg_exit, status, truncate(ffmpeg_output, 1000)}}
    end
  end

  defp codec_args("aac"), do: {:ok, ["-codec:a", "aac", "-b:a", "128k"]}
  defp codec_args("mp3"), do: {:ok, ["-codec:a", "libmp3lame", "-b:a", "128k"]}
  defp codec_args("wav"), do: {:ok, ["-c:a", "pcm_s16le"]}
  defp codec_args("opus"), do: {:ok, ["-c:a", "libopus", "-b:a", "96k"]}
  defp codec_args(other), do: {:error, {:unsupported_codec, other}}

  defp build_key(embed_hash, version, codec, container, track_spec) do
    with {:ok, embed_hash} <- StepSupport.require_binary(embed_hash, :embed_hash) do
      filename = audio_filename(track_spec, codec, container)
      {:ok, versioned_audio_key(embed_hash, version, filename)}
    end
  end

  defp audio_filename(%{"default_filename" => true}, "mp3", "mp3"), do: "audio.mp3"

  defp audio_filename(%{"default_filename" => true}, codec, container),
    do: "audio_#{codec}.#{container}"

  defp audio_filename(track_spec, codec, container),
    do: "#{track_spec["id"]}_#{codec}.#{container}"

  defp versioned_audio_key(embed_hash, version, filename) do
    case StepSupport.normalize_version(version) do
      normalized_version when normalized_version > 0 ->
        "#{embed_hash}/v#{normalized_version}/#{filename}"

      _ ->
        "#{embed_hash}/#{filename}"
    end
  end

  defp put_audio(storage_adapter, bucket, key, body, container, region) do
    case storage_adapter.put_public(bucket, key, body, media_type(container), region) do
      {:ok, _body} -> {:ok, "s3://#{bucket}/#{key}"}
      {:error, reason} -> {:error, {:audio_upload_failed, reason}}
    end
  end

  defp unavailable_output(step_id, codec, container, reason) do
    %{
      "status" => "unavailable",
      "step_type" => "media.transcode_audio",
      "mode" => "failed",
      "step_id" => step_id,
      "codec" => codec,
      "container" => container,
      "error" => inspect(reason)
    }
  end

  defp skipped_output(step_id, codec, container, reason) do
    %{
      "status" => "skipped",
      "step_type" => "media.transcode_audio",
      "mode" => "skipped",
      "step_id" => step_id,
      "codec" => codec,
      "container" => container,
      "reason" => reason
    }
  end

  defp container_for_codec("aac"), do: "m4a"
  defp container_for_codec("mp3"), do: "mp3"
  defp container_for_codec("wav"), do: "wav"
  defp container_for_codec("opus"), do: "ogg"
  defp container_for_codec(_), do: "m4a"

  defp no_audio_stream_error?(stderr) when is_binary(stderr) do
    String.contains?(stderr, "matches no streams") or
      (String.contains?(stderr, "Invalid argument") and String.contains?(stderr, "option 'map'"))
  end

  defp no_audio_stream_error?(_), do: false

  defp media_type("m4a"), do: "audio/mp4"
  defp media_type("mp3"), do: "audio/mpeg"
  defp media_type("wav"), do: "audio/wav"
  defp media_type("ogg"), do: "audio/ogg"
  defp media_type(_), do: "application/octet-stream"

  defp artifact_name("default", codec), do: "audio_#{codec}"
  defp artifact_name(track_id, codec), do: "#{track_id}_#{codec}"

  defp normalize_param(nil, default), do: default
  defp normalize_param(value, _default) when is_binary(value) and value != "", do: value
  defp normalize_param(value, _default) when is_atom(value), do: Atom.to_string(value)
  defp normalize_param(_value, default), do: default

  defp normalize_boolean(value, _default) when value in [true, "true", 1, "1"], do: true
  defp normalize_boolean(value, _default) when value in [false, "false", 0, "0"], do: false
  defp normalize_boolean(_value, default), do: default

  defp inspect_reports_no_audio?(inspect_output) when is_map(inspect_output) do
    Map.get(inspect_output, "has_audio", Map.get(inspect_output, :has_audio)) == false
  end

  defp inspect_reports_no_audio?(_), do: false

  defp default_stream?(stream) do
    stream
    |> map_get("disposition", %{})
    |> map_get("default")
    |> case do
      1 -> true
      "1" -> true
      true -> true
      _ -> false
    end
  end

  defp stream_label(stream, _selector, true, fallback_label) do
    stream
    |> map_get("tags", %{})
    |> map_get("title")
    |> normalize_param(fallback_label)
  end

  defp stream_label(stream, selector, false, _fallback_label) do
    stream
    |> map_get("tags", %{})
    |> map_get("title")
    |> normalize_param("Track #{selector + 1}")
  end

  defp stream_language(stream, fallback) do
    stream
    |> map_get("tags", %{})
    |> map_get("language")
    |> normalize_language(fallback)
  end

  defp normalize_language(nil, fallback), do: fallback

  defp normalize_language(language, fallback) when is_binary(language) do
    normalized =
      language
      |> String.trim()
      |> String.downcase()
      |> String.replace("-", "_")

    cond do
      normalized == "" -> fallback
      byte_size(normalized) >= 2 -> String.slice(normalized, 0, 2)
      true -> fallback
    end
  end

  defp normalize_language(_language, fallback), do: fallback

  defp map_get(nil, _key), do: nil

  defp map_get(map, key) when is_map(map) do
    map_get(map, key, nil)
  end

  defp map_get(_map, _key), do: nil

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

  defp map_atom_string_value(map, map_key, key) when is_atom(map_key) do
    if Atom.to_string(map_key) == key, do: Map.get(map, map_key), else: nil
  end

  defp map_atom_string_value(_map, _map_key, _key), do: nil

  defp truncate(value, max) when is_binary(value) and is_integer(max) and max > 3 do
    if String.length(value) <= max do
      value
    else
      String.slice(value, 0, max - 3) <> "..."
    end
  end

  defp truncate(value, _max), do: inspect(value)
end
