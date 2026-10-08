defmodule MaveCore.Flow.Steps.MediaPackageHlsAudioStep do
  @moduledoc """
  Packages an audio rendition into HLS (fMP4) files for master playlist audio groups.
  """
  @behaviour MaveCore.Flow.Step

  alias MaveCore.EncodingBooster
  alias MaveCore.EncodingBooster.HLSUpload
  alias MaveCore.Flow.Steps.Support, as: StepSupport
  alias MaveCore.Media.Signature
  alias MaveCore.Media.Storage

  @impl true
  def run(step_definition, context) do
    run_input = Map.get(context, :run_input, %{})
    dependency_outputs = Map.get(context, :dependency_outputs, %{})
    source_output = Map.get(dependency_outputs, "source", %{})
    params = Map.get(step_definition, "params", %{})
    step_id = Map.get(step_definition, "id", "hls_audio")
    strict? = StepSupport.strict_enabled?(params, run_input, "media_package_hls_audio_strict")

    audio_output = select_audio_output(dependency_outputs, params)

    audio_output_status =
      audio_output
      |> map_get("status")
      |> normalize_param("ok")

    if audio_output_status in ["skipped", "unavailable"] do
      {:ok, skipped_output(step_id, audio_output_status), []}
    else
      space_hash = resolve_space_hash(audio_output, source_output, run_input)
      embed_hash = resolve_embed_hash(audio_output, source_output, run_input)

      version =
        StepSupport.normalize_version(resolve_version(audio_output, source_output, run_input))

      region = map_get(run_input, "region")
      storage_adapter = Application.get_env(:mave_core, :flow_storage_adapter, Storage)
      bucket = Storage.bucket_for_space(space_hash, region)

      channels = normalize_integer(map_get(params, "channels"), 2)
      bandwidth = normalize_integer(map_get(params, "bandwidth"), 128_000)
      tracks = resolve_audio_tracks(audio_output)

      progress =
        StepSupport.ffmpeg_progress(Map.get(context, :progress_reporter), %{
          stage: "package_hls",
          step_id: step_id,
          codec: "aac",
          size: "audio",
          container: "hls",
          total_ms: StepSupport.inspect_duration_ms(dependency_outputs)
        })

      package_context = %{
        audio_output: audio_output,
        params: params,
        storage_adapter: storage_adapter,
        ffmpeg_bin: nil,
        bucket: bucket,
        embed_hash: embed_hash,
        version: version,
        channels: channels,
        bandwidth: bandwidth,
        region: region,
        progress: progress,
        run_input: run_input,
        dependency_outputs: dependency_outputs,
        encoding_booster_dispatch: Map.get(context, :encoding_booster_dispatch)
      }

      with {:ok, _validated_space_hash} <- StepSupport.require_binary(space_hash, :space_hash),
           {:ok, _validated_embed_hash} <- StepSupport.require_binary(embed_hash, :embed_hash),
           {:ok, ffmpeg_bin} <- package_ffmpeg_bin(context),
           {:ok, packaged_tracks} <-
             package_audio_tracks(tracks, %{package_context | ffmpeg_bin: ffmpeg_bin}) do
        primary_track =
          Enum.find(packaged_tracks, &get_in(&1, ["audio_track", "default"])) ||
            hd(packaged_tracks)

        audio_tracks = Enum.map(packaged_tracks, & &1["audio_track"])
        renditions = Enum.map(packaged_tracks, & &1["rendition"])
        artifacts = Enum.flat_map(packaged_tracks, & &1["artifacts"])
        files = Enum.flat_map(packaged_tracks, & &1["files"])
        segment_count = Enum.reduce(packaged_tracks, 0, &(&1["segment_count"] + &2))
        total_size = Enum.reduce(packaged_tracks, 0, &(&1["file_size"] + &2))

        output =
          %{
            "status" => "ok",
            "step_type" => "media.package_hls_audio",
            "step_id" => step_id,
            "track_id" => primary_track["track_id"],
            "label" => primary_track["label"],
            "language" => primary_track["language"],
            "default" => primary_track["default"],
            "container" => "hls",
            "bucket" => bucket,
            "variant_dir" => primary_track["variant_dir"],
            "playlist_key" => primary_track["playlist_key"],
            "playlist_uri" => primary_track["playlist_uri"],
            "playlist_path" => primary_track["playlist_path"],
            "bandwidth" => bandwidth,
            "channels" => Integer.to_string(channels),
            "files" => files,
            "segment_count" => segment_count,
            "file_size" => total_size,
            "audio_track" => primary_track["audio_track"],
            "audio_tracks" => audio_tracks,
            "rendition" => primary_track["rendition"],
            "renditions" => renditions
          }
          |> maybe_put_encoding_booster_output(primary_track)

        {:ok, output, artifacts}
      else
        {:error, {:encoding_booster_fallback_required, _code, _reason} = reason} ->
          {:error, reason}

        {:error, :encoding_booster_busy} ->
          {:error, {:media_package_hls_audio_failed, :encoding_booster_busy}}

        {:error, reason} when strict? ->
          {:error, {:media_package_hls_audio_failed, reason}}

        {:error, reason} ->
          {:ok, unavailable_output(step_id, reason), []}
      end
    end
  end

  defp package_ffmpeg_bin(%{encoding_booster_dispatch: :direct}), do: {:ok, nil}
  defp package_ffmpeg_bin(_context), do: StepSupport.find_ffmpeg()

  defp select_audio_output(dependency_outputs, params) do
    preferred_step_id = normalize_param(map_get(params, "source_step_id"), nil)
    preferred_output = preferred_audio_output(dependency_outputs, preferred_step_id)

    if map_size(preferred_output) > 0 do
      preferred_output
    else
      find_audio_transcode_output(dependency_outputs)
    end
  end

  defp resolve_audio_tracks(audio_output) do
    case map_get(audio_output, "audio_tracks") do
      tracks when is_list(tracks) ->
        tracks
        |> Enum.filter(&is_map/1)
        |> normalize_resolved_audio_tracks(audio_output)

      _ ->
        [map_get(audio_output, "audio_track", %{})]
    end
    |> Enum.filter(&is_map/1)
  end

  defp package_audio_tracks(tracks, package_context) do
    tracks
    |> Enum.reduce_while({:ok, []}, fn track, {:ok, acc} ->
      case package_audio_track(track, package_context) do
        {:ok, packaged_track} ->
          {:cont, {:ok, acc ++ [packaged_track]}}

        {:error, reason} ->
          {:halt, {:error, reason}}
      end
    end)
  end

  defp package_audio_track(track, package_context) do
    track_meta = packaged_track_meta(track, package_context)
    variant_dir = build_variant_dir(track, package_context.params)

    with {:ok, source_ref} <-
           resolve_source_ref(track, package_context.audio_output, package_context.bucket),
         {:ok, packaged} <- package_audio(package_context, source_ref, variant_dir) do
      {:ok, build_packaged_audio_track(track, track_meta, packaged, package_context, variant_dir)}
    end
  end

  defp packaged_track_meta(track, package_context) do
    %{
      track_id:
        normalize_param(
          map_get(package_context.params, "track_id"),
          map_get(track, "id") || "default"
        ),
      label:
        normalize_param(
          map_get(package_context.params, "label"),
          map_get(track, "label") || "Original"
        ),
      language:
        normalize_param(map_get(package_context.params, "language"), map_get(track, "language")),
      default:
        normalize_boolean(
          map_get(package_context.params, "default"),
          map_get(track, "default", false)
        )
    }
  end

  defp build_packaged_audio_track(track, track_meta, packaged, package_context, variant_dir) do
    playlist_relative_path = "#{variant_dir}/playlist.m3u8"

    audio_track =
      build_hls_audio_track(track, track_meta, packaged, package_context, playlist_relative_path)

    rendition = build_hls_audio_rendition(packaged)

    %{
      "track_id" => track_meta.track_id,
      "label" => track_meta.label,
      "language" => track_meta.language,
      "default" => track_meta.default,
      "variant_dir" => variant_dir,
      "playlist_key" => packaged.playlist_key,
      "playlist_uri" => packaged.playlist_uri,
      "playlist_path" => playlist_relative_path,
      "files" => packaged.files,
      "segment_count" => packaged.segment_count,
      "file_size" => packaged.total_size,
      "audio_track" => audio_track,
      "rendition" => rendition,
      "artifacts" =>
        build_hls_audio_artifacts(track_meta, packaged, package_context, variant_dir),
      "mode" => Map.get(packaged, :mode),
      "encoding_booster_elapsed_ms" => Map.get(packaged, :encoding_booster_elapsed_ms),
      "encoding_booster_instance" => Map.get(packaged, :encoding_booster_instance)
    }
  end

  defp resolve_source_ref(track, audio_output, default_bucket) do
    key = source_ref_key(track, audio_output)
    bucket = source_ref_bucket(track, audio_output, default_bucket)
    uri = source_ref_uri(track, audio_output)

    case valid_audio_source_ref(bucket, key) do
      true -> {:ok, %{bucket: bucket, key: key, uri: uri}}
      false -> resolve_audio_uri_source(uri)
    end
  end

  defp package_audio(package_context, source_ref, variant_dir) do
    if package_context.encoding_booster_dispatch == :direct do
      package_audio_with_booster(package_context, source_ref, variant_dir)
    else
      package_audio_locally(package_context, source_ref, variant_dir)
    end
  end

  defp package_audio_locally(package_context, source_ref, variant_dir) do
    StepSupport.with_temp_dir("hls_audio", fn tmp_dir ->
      package_context
      |> package_audio_once(source_ref, variant_dir, tmp_dir, false)
      |> maybe_retry_package_audio_from_download(
        package_context,
        source_ref,
        variant_dir,
        tmp_dir
      )
    end)
  end

  defp package_audio_with_booster(package_context, source_ref, variant_dir) do
    prefix =
      base_prefix(package_context.embed_hash, package_context.version) <> variant_dir <> "/"

    with {:ok, input_url} <-
           package_context.storage_adapter.presigned_get_url(
             source_ref.bucket,
             source_ref.key,
             package_context.region,
             expires: 2 * 60 * 60
           ),
         {:ok, upload_token} <-
           HLSUpload.sign(
             package_context.bucket,
             prefix,
             package_context.region,
             media_kind: "audio"
           ),
         {:ok, booster_result} <-
           encoding_booster_adapter().package_hls_to_storage(
             input_url,
             upload_token,
             media_kind: "audio",
             channels: package_context.channels
           ),
         {:ok, files} <- verify_booster_hls_files(package_context, booster_result.files) do
      report_booster_completed(package_context, booster_result, files)

      {:ok,
       packaged_audio(files, prefix <> "playlist.m3u8", package_context.bucket)
       |> Map.put(:mode, "encoding_booster")
       |> Map.put(:encoding_booster_elapsed_ms, booster_result.elapsed_ms)
       |> maybe_put_booster_instance(booster_result)}
    else
      {:error, reason} -> booster_error(reason)
    end
  end

  defp verify_booster_hls_files(package_context, files) when is_list(files) do
    files
    |> Task.async_stream(
      &verify_booster_hls_file(package_context, &1),
      max_concurrency: storage_object_max_concurrency(),
      ordered: true,
      timeout: :infinity
    )
    |> Enum.reduce_while({:ok, []}, fn
      {:ok, {:ok, file}}, {:ok, verified} ->
        {:cont, {:ok, [file | verified]}}

      {:ok, {:error, reason}}, {:ok, _verified} ->
        {:halt, {:error, reason}}

      {:exit, reason}, {:ok, _verified} ->
        {:halt, {:error, {:hls_upload_verification_failed, reason}}}
    end)
    |> case do
      {:ok, verified} -> validate_booster_hls_file_set(Enum.reverse(verified))
      {:error, _reason} = error -> error
    end
  end

  defp verify_booster_hls_files(_package_context, _files),
    do: {:error, :invalid_encoding_booster_response}

  defp verify_booster_hls_file(package_context, %{
         "name" => name,
         "key" => key,
         "file_size" => expected_size,
         "content_type" => content_type
       })
       when is_binary(name) and is_binary(key) and is_integer(expected_size) and expected_size > 0 do
    case package_context.storage_adapter.object_info(
           package_context.bucket,
           key,
           package_context.region
         ) do
      {:ok, %{size_bytes: ^expected_size}} ->
        {:ok,
         %{
           "name" => name,
           "key" => key,
           "uri" => "s3://#{package_context.bucket}/#{key}",
           "file_size" => expected_size,
           "content_type" => content_type
         }}

      {:ok, %{size_bytes: actual_size}} ->
        {:error, {:hls_upload_size_mismatch, name, expected_size, actual_size}}

      {:error, reason} ->
        {:error, {:hls_upload_verification_failed, name, reason}}

      _other ->
        {:error, {:hls_upload_verification_failed, name, :invalid_object_info}}
    end
  end

  defp verify_booster_hls_file(_package_context, _file),
    do: {:error, :invalid_encoding_booster_response}

  defp validate_booster_hls_file_set(files) do
    names = MapSet.new(files, & &1["name"])

    if MapSet.member?(names, "playlist.m3u8") and MapSet.member?(names, "init.mp4") and
         Enum.any?(names, &String.ends_with?(&1, ".m4s")) do
      {:ok, files}
    else
      {:error, :incomplete_encoding_booster_bundle}
    end
  end

  defp report_booster_completed(%{progress: nil}, _booster_result, _files), do: :ok

  defp report_booster_completed(package_context, booster_result, files) do
    total_size_bytes = Enum.reduce(files, 0, &(&1["file_size"] + &2))

    StepSupport.report_progress(package_context.progress.reporter, %{
      "source" => "ffmpeg",
      "executor" => "encoding_booster",
      "status" => "completed",
      "stage" => "package_hls",
      "step_id" => package_context.progress.step_id,
      "codec" => "aac",
      "size" => "audio",
      "container" => "hls",
      "percent" => 100.0,
      "total_ms" => package_context.progress.total_ms,
      "ffmpeg_elapsed_ms" => booster_result.ffmpeg_elapsed_ms,
      "total_size_bytes" => total_size_bytes,
      "force" => true
    })
  end

  defp maybe_put_encoding_booster_output(output, %{"mode" => "encoding_booster"} = track) do
    output
    |> Map.put("mode", "encoding_booster")
    |> Map.put("encoding_booster_elapsed_ms", track["encoding_booster_elapsed_ms"])
    |> maybe_put_encoding_booster_instance(track["encoding_booster_instance"])
  end

  defp maybe_put_encoding_booster_output(output, _track), do: output

  defp maybe_put_encoding_booster_instance(output, instance_id) when is_binary(instance_id),
    do: Map.put(output, "encoding_booster_instance", instance_id)

  defp maybe_put_encoding_booster_instance(output, _instance_id), do: output

  defp maybe_put_booster_instance(packaged, %{instance_id: instance_id})
       when is_binary(instance_id),
       do: Map.put(packaged, :encoding_booster_instance, instance_id)

  defp maybe_put_booster_instance(packaged, _booster_result), do: packaged

  defp booster_error(:encoding_booster_busy), do: {:error, :encoding_booster_busy}

  defp booster_error(reason) do
    if EncodingBooster.fallback_enabled?() do
      {:error, {:encoding_booster_fallback_required, encoding_booster_error_code(reason), reason}}
    else
      {:error, reason}
    end
  end

  defp encoding_booster_error_code(:encoding_booster_busy), do: "busy"
  defp encoding_booster_error_code({:encoding_booster_http_status, status}), do: "http_#{status}"
  defp encoding_booster_error_code(_reason), do: "request_failed"

  defp encoding_booster_adapter do
    Application.get_env(:mave_core, :encoding_booster_adapter, EncodingBooster)
  end

  defp storage_object_max_concurrency do
    case Application.get_env(:mave_core, :storage_object_max_concurrency, 8) do
      value when is_integer(value) and value > 0 -> value
      _other -> 8
    end
  end

  defp maybe_retry_package_audio_from_download(
         {:error, {:ffmpeg_exit, _status, ffmpeg_output} = reason},
         package_context,
         source_ref,
         variant_dir,
         tmp_dir
       ) do
    if StepSupport.ffmpeg_storage_read_error?(ffmpeg_output) do
      package_audio_once(package_context, source_ref, variant_dir, tmp_dir, true)
    else
      {:error, reason}
    end
  end

  defp maybe_retry_package_audio_from_download(
         result,
         _package_context,
         _source_ref,
         _variant_dir,
         _tmp_dir
       ) do
    result
  end

  defp package_audio_once(package_context, source_ref, variant_dir, tmp_dir, force_download?) do
    hls_dir_basename = if force_download?, do: "hls_download", else: "hls"

    with {:ok, input_path} <-
           download_input(
             package_context.storage_adapter,
             source_ref,
             package_context.region,
             tmp_dir,
             force_download: force_download?
           ),
         {:ok, hls_dir} <- prepare_hls_dir(tmp_dir, hls_dir_basename),
         :ok <-
           run_hls_ffmpeg(
             package_context.ffmpeg_bin,
             input_path,
             hls_dir,
             package_context.channels,
             package_context.progress
           ),
         {:ok, files} <-
           upload_hls_dir(
             package_context.storage_adapter,
             package_context.bucket,
             hls_dir,
             package_context.embed_hash,
             package_context.version,
             variant_dir,
             package_context.region
           ) do
      playlist_key =
        base_prefix(package_context.embed_hash, package_context.version) <>
          variant_dir <> "/playlist.m3u8"

      {:ok, packaged_audio(files, playlist_key, package_context.bucket)}
    end
  end

  defp packaged_audio(files, playlist_key, bucket) do
    total_size = Enum.reduce(files, 0, fn file, acc -> acc + file["file_size"] end)
    segment_count = Enum.count(files, &String.ends_with?(&1["name"], ".m4s"))

    %{
      files: files,
      total_size: total_size,
      segment_count: segment_count,
      playlist_key: playlist_key,
      playlist_uri: "s3://#{bucket}/#{playlist_key}"
    }
  end

  defp run_hls_ffmpeg(ffmpeg_bin, input_path, hls_dir, channels, progress) do
    segment_pattern = Path.join(hls_dir, "segment_%03d.m4s")
    playlist_path = Path.join(hls_dir, "playlist.m3u8")

    args = [
      "-hide_banner",
      "-loglevel",
      "error",
      "-y",
      "-format_whitelist",
      Signature.audio_formats(),
      "-i",
      input_path,
      "-map_metadata",
      "-1",
      "-c:a",
      "aac",
      "-b:a",
      "128k",
      "-ac",
      Integer.to_string(channels),
      "-hls_time",
      "6",
      "-hls_playlist_type",
      "vod",
      "-hls_segment_type",
      "fmp4",
      "-hls_fmp4_init_filename",
      "init.mp4",
      "-hls_segment_filename",
      segment_pattern,
      playlist_path
    ]

    case StepSupport.run_media_cmd(ffmpeg_bin, args, progress: progress) do
      {_output, 0} ->
        :ok

      {stderr, status} ->
        {:error, {:ffmpeg_exit, status, truncate(stderr, 1000)}}
    end
  end

  defp upload_hls_dir(storage_adapter, bucket, hls_dir, embed_hash, version, variant_dir, region) do
    case File.ls(hls_dir) do
      {:ok, files} ->
        files
        |> upload_hls_files(
          storage_adapter,
          bucket,
          hls_dir,
          embed_hash,
          version,
          variant_dir,
          region
        )
        |> case do
          {:ok, uploaded} -> {:ok, Enum.reverse(uploaded)}
          {:error, reason} -> {:error, reason}
        end

      {:error, reason} ->
        {:error, {:hls_dir_read_failed, reason}}
    end
  end

  defp download_input(_storage_adapter, source_ref, region, tmp_dir, opts) do
    case StepSupport.prepare_storage_ffmpeg_input(
           tmp_dir,
           source_ref.bucket,
           source_ref.key,
           region,
           "audio/mpeg",
           Map.get(source_ref, :uri),
           "audio",
           opts
         ) do
      {:ok, input} -> {:ok, input}
      {:error, reason} -> {:error, {:source_fetch_failed, reason}}
    end
  end

  defp prepare_hls_dir(tmp_dir, basename) do
    with {:ok, hls_dir} <- StepSupport.tmp_file_path(tmp_dir, basename),
         :ok <- StepSupport.mkdir_tmp_dir(hls_dir) do
      {:ok, hls_dir}
    else
      {:error, reason} -> {:error, {:hls_dir_create_failed, reason}}
    end
  end

  defp build_variant_dir(track, params) do
    case normalize_param(map_get(params, "variant_dir"), nil) do
      nil ->
        filename = map_get(track, "filename") || "audio.mp3"
        basename = filename |> Path.basename() |> Path.rootname()
        "#{basename}_hls"

      variant_dir ->
        variant_dir
    end
  end

  defp playlist_size(files) do
    files
    |> Enum.find_value(fn file ->
      if file["name"] == "playlist.m3u8", do: file["file_size"], else: nil
    end)
  end

  defp hls_content_type(file_name) do
    cond do
      String.ends_with?(file_name, ".m3u8") -> "application/vnd.apple.mpegurl"
      String.ends_with?(file_name, ".m4s") -> "audio/mp4"
      file_name == "init.mp4" -> "audio/mp4"
      true -> "application/octet-stream"
    end
  end

  defp base_prefix(embed_hash, version) do
    if version > 0 do
      "#{embed_hash}/v#{version}/"
    else
      "#{embed_hash}/"
    end
  end

  defp parse_s3_uri("s3://" <> rest) do
    case String.split(rest, "/", parts: 2) do
      [bucket, key] when bucket != "" and key != "" ->
        {:ok, %{bucket: bucket, key: key, uri: "s3://#{bucket}/#{key}"}}

      _ ->
        {:error, :invalid_source_uri}
    end
  end

  defp parse_s3_uri(_), do: {:error, :invalid_source_uri}

  defp skipped_output(step_id, reason) do
    %{
      "status" => "skipped",
      "step_type" => "media.package_hls_audio",
      "step_id" => step_id,
      "container" => "hls",
      "reason" => reason
    }
  end

  defp unavailable_output(step_id, reason) do
    %{
      "status" => "unavailable",
      "step_type" => "media.package_hls_audio",
      "step_id" => step_id,
      "container" => "hls",
      "error" => inspect(reason)
    }
  end

  defp resolve_space_hash(audio_output, source_output, run_input) do
    map_get(audio_output, "space_hash") ||
      map_get(source_output, "space_hash") ||
      map_get(run_input, "space_hash")
  end

  defp resolve_embed_hash(audio_output, source_output, run_input) do
    map_get(audio_output, "embed_hash") ||
      map_get(source_output, "embed_hash") ||
      map_get(run_input, "embed_hash")
  end

  defp resolve_version(audio_output, source_output, run_input) do
    map_get(audio_output, "version") ||
      map_get(source_output, "version") ||
      map_get(run_input, "version", 0)
  end

  defp map_get(map, key, default \\ nil)

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

  defp source_ref_key(track, audio_output) do
    map_get(track, "key") || map_get(audio_output, "key")
  end

  defp source_ref_bucket(track, audio_output, default_bucket) do
    map_get(track, "bucket") || map_get(audio_output, "bucket") || default_bucket
  end

  defp source_ref_uri(track, audio_output) do
    map_get(track, "src") || map_get(track, "path") || map_get(audio_output, "uri")
  end

  defp valid_audio_source_ref(bucket, key) do
    is_binary(bucket) and bucket != "" and is_binary(key) and key != ""
  end

  defp resolve_audio_uri_source(uri) when is_binary(uri), do: parse_s3_uri(uri)
  defp resolve_audio_uri_source(_uri), do: {:error, :missing_audio_source}

  defp preferred_audio_output(_dependency_outputs, nil), do: %{}

  defp preferred_audio_output(dependency_outputs, preferred_step_id) do
    case Map.get(dependency_outputs, preferred_step_id) do
      %{} = output -> output
      _ -> %{}
    end
  end

  defp find_audio_transcode_output(dependency_outputs) do
    Enum.find_value(dependency_outputs, %{}, fn {_step_id, output} ->
      if is_map(output) and output["step_type"] == "media.transcode_audio", do: output, else: nil
    end)
  end

  defp normalize_resolved_audio_tracks([], audio_output),
    do: [map_get(audio_output, "audio_track", %{})]

  defp normalize_resolved_audio_tracks(resolved, _audio_output), do: resolved

  defp build_hls_audio_track(track, track_meta, packaged, package_context, playlist_relative_path) do
    source_uri =
      map_get(track, "src") || map_get(track, "path") ||
        map_get(package_context.audio_output, "uri")

    %{
      "id" => track_meta.track_id,
      "label" => track_meta.label,
      "language" => track_meta.language,
      "default" => track_meta.default,
      "codec" => map_get(track, "codec") || "aac",
      "file_size" => map_get(track, "file_size"),
      "filename" => map_get(track, "filename") || "audio.mp3",
      "path" => source_uri,
      "src" => source_uri,
      "hls_playlist" => playlist_relative_path,
      "hls_src" => packaged.playlist_uri,
      "hls_file_size" => packaged.total_size,
      "hls_codec" => "aac",
      "hls_group_id" => "audio",
      "hls_bandwidth" => package_context.bandwidth,
      "hls_channels" => Integer.to_string(package_context.channels)
    }
  end

  defp build_hls_audio_rendition(packaged) do
    %{
      "type" => "audio",
      "size" => nil,
      "codec" => "aac",
      "container" => "hls",
      "progress" => 100.0,
      "rendition_key" => packaged.playlist_key,
      "src" => packaged.playlist_uri,
      "file_size" => packaged.total_size
    }
  end

  defp build_hls_audio_artifacts(track_meta, packaged, package_context, variant_dir) do
    [
      %{
        name: "#{variant_dir}_playlist",
        uri: packaged.playlist_uri,
        media_type: "application/vnd.apple.mpegurl",
        size_bytes: playlist_size(packaged.files),
        metadata: %{
          "type" => "audio",
          "container" => "hls",
          "track_id" => track_meta.track_id,
          "space_hash" => map_get(package_context.audio_output, "space_hash"),
          "embed_hash" => package_context.embed_hash,
          "version" => package_context.version
        }
      }
    ]
  end

  defp upload_hls_files(
         files,
         storage_adapter,
         bucket,
         hls_dir,
         embed_hash,
         version,
         variant_dir,
         region
       ) do
    upload_context = %{
      storage_adapter: storage_adapter,
      bucket: bucket,
      hls_dir: hls_dir,
      embed_hash: embed_hash,
      version: version,
      variant_dir: variant_dir,
      region: region
    }

    files
    |> Enum.sort()
    |> Enum.reduce_while({:ok, []}, fn file_name, {:ok, acc} ->
      reduce_uploaded_hls_audio_file(file_name, acc, upload_context)
    end)
  end

  defp reduce_uploaded_hls_audio_file(file_name, acc, upload_context) do
    local_path = Path.join(upload_context.hls_dir, file_name)

    case upload_hls_audio_file(
           upload_context.storage_adapter,
           upload_context.bucket,
           local_path,
           upload_context.embed_hash,
           upload_context.version,
           upload_context.variant_dir,
           file_name,
           upload_context.region
         ) do
      {:ok, uploaded} ->
        {:cont, {:ok, [uploaded | acc]}}

      {:error, reason} ->
        {:halt, {:error, {:hls_upload_failed, file_name, reason}}}
    end
  end

  defp upload_hls_audio_file(
         storage_adapter,
         bucket,
         local_path,
         embed_hash,
         version,
         variant_dir,
         file_name,
         region
       ) do
    with {:ok, %{size: size}} <- File.stat(local_path),
         key <- base_prefix(embed_hash, version) <> variant_dir <> "/" <> file_name,
         content_type = hls_content_type(file_name),
         {:ok, _} <-
           storage_adapter.put_file_public(bucket, key, local_path, content_type, region) do
      {:ok,
       %{
         "name" => file_name,
         "key" => key,
         "uri" => "s3://#{bucket}/#{key}",
         "file_size" => size,
         "content_type" => content_type
       }}
    end
  end

  defp map_atom_string_value(map, map_key, key) when is_atom(map_key) do
    if Atom.to_string(map_key) == key, do: Map.get(map, map_key), else: nil
  end

  defp map_atom_string_value(_map, _map_key, _key), do: nil

  defp normalize_param(nil, default), do: default
  defp normalize_param(value, _default) when is_binary(value) and value != "", do: value
  defp normalize_param(value, _default) when is_atom(value), do: Atom.to_string(value)
  defp normalize_param(value, _default) when is_integer(value), do: Integer.to_string(value)
  defp normalize_param(_value, default), do: default

  defp normalize_integer(value, _default) when is_integer(value) and value > 0, do: value

  defp normalize_integer(value, default) when is_binary(value) do
    case Integer.parse(value) do
      {parsed, ""} when parsed > 0 -> parsed
      _ -> default
    end
  end

  defp normalize_integer(_value, default), do: default

  defp normalize_boolean(value, _default) when value in [true, "true", 1, "1"], do: true
  defp normalize_boolean(value, _default) when value in [false, "false", 0, "0"], do: false
  defp normalize_boolean(_value, default), do: default

  defp truncate(value, max) when is_binary(value) and is_integer(max) and max > 3 do
    if String.length(value) <= max do
      value
    else
      String.slice(value, 0, max - 3) <> "..."
    end
  end

  defp truncate(value, _max), do: inspect(value)
end
