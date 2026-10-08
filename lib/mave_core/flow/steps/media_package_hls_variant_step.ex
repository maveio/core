defmodule MaveCore.Flow.Steps.MediaPackageHlsVariantStep do
  @moduledoc """
  Packages a single transcoded video rendition into HLS (fMP4) files.

  This mirrors the `mave-encoder` HLS command shape:
  - `init.mp4`
  - `segment_%03d.m4s`
  - `playlist.m3u8`
  """
  @behaviour MaveCore.Flow.Step

  alias MaveCore.EncodingBooster
  alias MaveCore.EncodingBooster.HLSUpload
  alias MaveCore.Flow.Steps.Support, as: StepSupport
  alias MaveCore.Media.Storage

  @variant_profiles %{
    "sd" => %{bandwidth: 3_000_000, resolution: "842x480"},
    "hd" => %{bandwidth: 4_000_000, resolution: "1280x720"},
    "fhd" => %{bandwidth: 6_000_000, resolution: "1920x1080"},
    "qhd" => %{bandwidth: 8_000_000, resolution: "2560x1440"},
    "uhd" => %{bandwidth: 10_000_000, resolution: "3840x2160"}
  }

  @impl true
  def run(step_definition, context) do
    run_input = Map.get(context, :run_input, %{})
    dependency_outputs = Map.get(context, :dependency_outputs, %{})
    progress_reporter = Map.get(context, :progress_reporter)
    source_output = Map.get(dependency_outputs, "source", %{})
    params = Map.get(step_definition, "params", %{})
    step_id = Map.get(step_definition, "id", "hls_variant")

    video_output = select_video_output(dependency_outputs, params)
    space_hash = resolve_space_hash(video_output, source_output, run_input)
    embed_hash = resolve_embed_hash(video_output, source_output, run_input)
    version = resolve_version(video_output, source_output, run_input)
    region = Map.get(run_input, "region")
    codec = normalize_param(Map.get(params, "codec"), map_get(video_output, "codec") || "h264")
    size = normalize_param(Map.get(params, "size"), map_get(video_output, "size") || "sd")
    strict? = StepSupport.strict_enabled?(params, run_input, "media_package_hls_variant_strict")
    storage_adapter = Application.get_env(:mave_core, :flow_storage_adapter, Storage)
    bucket = Storage.bucket_for_space(space_hash, region)

    cond do
      skip_for_video_source?(params, dependency_outputs) ->
        {:ok, skipped_output(step_id, codec, size, "source has video"), []}

      skipped_video_output?(video_output) ->
        reason = map_get(video_output, "reason") || map_get(video_output, "status")
        {:ok, skipped_output(step_id, codec, size, reason), []}

      prepackaged_hls_output?(video_output, codec, size) ->
        output =
          video_output
          |> map_get("hls")
          |> normalize_prepackaged_output(step_id)

        {:ok, output, artifacts_from_output(output, space_hash, embed_hash, version)}

      Map.get(context, :encoding_booster_dispatch) == :direct ->
        package_variant_with_encoding_booster(%{
          context: context,
          run_input: run_input,
          dependency_outputs: dependency_outputs,
          video_output: video_output,
          params: params,
          step_id: step_id,
          codec: codec,
          size: size,
          space_hash: space_hash,
          embed_hash: embed_hash,
          version: version,
          region: region,
          bucket: bucket,
          storage_adapter: storage_adapter,
          strict?: strict?
        })

      true ->
        with {:ok, space_hash} <- StepSupport.require_binary(space_hash, :space_hash),
             {:ok, embed_hash} <- StepSupport.require_binary(embed_hash, :embed_hash),
             {:ok, source_ref} <- resolve_source_ref(video_output, bucket),
             {:ok, ffmpeg_bin} <- StepSupport.find_ffmpeg(),
             {:ok, variant_dir} <- build_variant_dir(codec, size, params),
             progress = ffmpeg_progress(progress_reporter, step_id, codec, size, video_output),
             {:ok, packaged} <-
               package_variant(%{
                 storage_adapter: storage_adapter,
                 ffmpeg_bin: ffmpeg_bin,
                 source_ref: source_ref,
                 bucket: bucket,
                 embed_hash: embed_hash,
                 version: StepSupport.normalize_version(version),
                 variant_dir: variant_dir,
                 region: region,
                 resolution: map_get(video_output, "resolution"),
                 progress: progress
               }) do
          output = output_from_packaged(step_id, codec, size, packaged)
          artifacts = artifacts_from_output(output, space_hash, embed_hash, version)

          {:ok, output, artifacts}
        else
          {:error, :missing_video_source} when strict? ->
            {:ok, skipped_output(step_id, codec, size, :missing_video_source), []}

          {:error, reason} when strict? ->
            {:error, {:media_package_hls_variant_failed, reason}}

          {:error, reason} ->
            {:ok, unavailable_output(step_id, codec, size, reason), []}
        end
    end
    |> defer_waveform_rendition(video_output)
  end

  defp skip_for_video_source?(params, dependency_outputs) do
    params["audio_only"] == true and not StepSupport.inspect_reports_no_video?(dependency_outputs)
  end

  # HLS video segments omit audio. Advertise them only after the master includes audio.
  defp defer_waveform_rendition(
         {:ok, %{"status" => "ok"} = output, artifacts},
         %{"step_type" => "media.transcode_waveform"}
       ) do
    output =
      output
      |> Map.put("waveform_rendition", output["rendition"])
      |> Map.delete("rendition")
      |> Map.put("renditions", [])

    {:ok, output, artifacts}
  end

  defp defer_waveform_rendition(result, _video_output), do: result

  defp package_variant_with_encoding_booster(package_context) do
    result =
      with {:ok, space_hash} <-
             StepSupport.require_binary(package_context.space_hash, :space_hash),
           {:ok, embed_hash} <-
             StepSupport.require_binary(package_context.embed_hash, :embed_hash),
           {:ok, input_url} <- booster_input_url(package_context),
           {:ok, output} <- run_encoding_booster_package(package_context, input_url) do
        artifacts =
          artifacts_from_output(
            output,
            space_hash,
            embed_hash,
            package_context.version
          )

        {:ok, output, artifacts}
      end

    case result do
      {:ok, _output, _artifacts} = success ->
        success

      {:error, :missing_video_source} when package_context.strict? ->
        {:ok,
         skipped_output(
           package_context.step_id,
           package_context.codec,
           package_context.size,
           :missing_video_source
         ), []}

      {:error, reason} when package_context.strict? ->
        {:error, {:media_package_hls_variant_failed, reason}}

      {:error, reason} ->
        {:ok,
         unavailable_output(
           package_context.step_id,
           package_context.codec,
           package_context.size,
           reason
         ), []}
    end
  end

  defp booster_input_url(package_context) do
    options =
      if package_context.video_output["step_type"] == "media.transcode_waveform" do
        [
          preferred_storage_step_id: package_context.params["source_step_id"],
          preferred_storage_content_type: "video/mp4"
        ]
      else
        [
          prefer_video_rendition: true,
          preferred_video_step_id: package_context.params["source_step_id"],
          preferred_video_codec: package_context.codec,
          preferred_video_size: package_context.size
        ]
      end

    StepSupport.encoding_booster_input_url(
      package_context.run_input,
      map_get(package_context.video_output, "uri"),
      package_context.dependency_outputs,
      options
    )
  end

  defp run_encoding_booster_package(package_context, input_url) do
    with {:ok, variant_dir} <-
           build_variant_dir(package_context.codec, package_context.size, package_context.params),
         {:ok, prefix, upload_token} <- hls_upload_destination(package_context, variant_dir),
         true <- encoding_booster_package_supported?(),
         {:ok, booster_result} <-
           encoding_booster_adapter().package_hls_to_storage(
             input_url,
             upload_token,
             encoding_booster_package_options(input_url)
           ),
         {:ok, files} <- verify_booster_hls_files(package_context, booster_result.files) do
      packaged =
        packaged_variant(
          files,
          prefix <> "playlist.m3u8",
          package_context.bucket,
          variant_dir,
          map_get(package_context.video_output, "resolution")
        )

      output =
        package_context.step_id
        |> output_from_packaged(package_context.codec, package_context.size, packaged)
        |> Map.put("mode", "encoding_booster")
        |> Map.put("encoding_booster_elapsed_ms", booster_result.elapsed_ms)
        |> maybe_put_booster_instance(booster_result)

      {:ok, output}
    else
      false -> {:error, :hls_direct_upload_unsupported}
      {:error, _reason} = error -> error
    end
  end

  defp hls_upload_destination(package_context, variant_dir) do
    prefix =
      base_prefix(
        package_context.embed_hash,
        StepSupport.normalize_version(package_context.version)
      ) <> variant_dir <> "/"

    case HLSUpload.sign(package_context.bucket, prefix, package_context.region) do
      {:ok, token} -> {:ok, prefix, token}
      {:error, _reason} = error -> error
    end
  end

  defp encoding_booster_package_supported? do
    adapter = encoding_booster_adapter()
    Code.ensure_loaded?(adapter) and function_exported?(adapter, :package_hls_to_storage, 3)
  end

  defp encoding_booster_package_options(input_url) do
    if Storage.ffmpeg_storage_url?(input_url) do
      case Storage.ffmpeg_input_referer() do
        referer when is_binary(referer) -> [input_referer: referer]
        _other -> []
      end
    else
      []
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

  defp maybe_put_booster_instance(output, %{instance_id: instance_id})
       when is_binary(instance_id),
       do: Map.put(output, "encoding_booster_instance", instance_id)

  defp maybe_put_booster_instance(output, _booster_result), do: output

  defp encoding_booster_adapter do
    Application.get_env(:mave_core, :encoding_booster_adapter, EncodingBooster)
  end

  @doc false
  def package_local_variant(opts) when is_map(opts) do
    codec = normalize_param(map_get(opts, :codec), "h264")
    size = normalize_param(map_get(opts, :size), "sd")
    params = map_get(opts, :params, %{})

    with {:ok, ffmpeg_bin} <- StepSupport.find_ffmpeg(),
         {:ok, variant_dir} <- build_variant_dir(codec, size, params),
         {:ok, packaged} <-
           package_variant_from_file(%{
             storage_adapter: map_get(opts, :storage_adapter),
             ffmpeg_bin: ffmpeg_bin,
             input_path: map_get(opts, :input_path),
             bucket: map_get(opts, :bucket),
             embed_hash: map_get(opts, :embed_hash),
             version: StepSupport.normalize_version(map_get(opts, :version)),
             variant_dir: variant_dir,
             region: map_get(opts, :region),
             resolution: map_get(opts, :resolution),
             progress: map_get(opts, :progress),
             tmp_dir: map_get(opts, :tmp_dir),
             hls_dir_basename: map_get(opts, :hls_dir_basename, "hls")
           }) do
      step_id = map_get(opts, :step_id, "hls_#{codec}_#{size}")
      {:ok, output_from_packaged(step_id, codec, size, packaged)}
    end
  end

  defp skipped_video_output?(%{} = video_output) do
    map_get(video_output, "status") in ["skipped", "unavailable"]
  end

  defp skipped_video_output?(_), do: false

  defp select_video_output(dependency_outputs, params) do
    preferred_step_id = normalize_param(Map.get(params, "source_step_id"), nil)
    codec = normalize_param(Map.get(params, "codec"), "h264")
    size = normalize_param(Map.get(params, "size"), "sd")

    dependency_outputs
    |> preferred_video_output(preferred_step_id)
    |> select_variant_output(codec, size)
    |> case do
      output when map_size(output) > 0 -> output
      _ -> find_transcode_output(dependency_outputs, codec, size)
    end
  end

  defp resolve_source_ref(video_output, default_bucket) do
    key = map_get(video_output, "key")
    bucket = map_get(video_output, "bucket") || default_bucket
    uri = map_get(video_output, "uri")

    cond do
      is_binary(bucket) and bucket != "" and is_binary(key) and key != "" ->
        {:ok, %{bucket: bucket, key: key, uri: uri}}

      is_binary(uri) ->
        parse_s3_uri(uri)

      true ->
        {:error, :missing_video_source}
    end
  end

  defp package_variant(package_context) do
    StepSupport.with_temp_dir("hls_variant", fn tmp_dir ->
      package_context
      |> package_variant_once(tmp_dir, false)
      |> maybe_retry_package_variant_from_download(package_context, tmp_dir)
    end)
  end

  defp maybe_retry_package_variant_from_download(
         {:error, {:ffmpeg_exit, _status, ffmpeg_output} = reason},
         package_context,
         tmp_dir
       ) do
    if StepSupport.ffmpeg_storage_read_error?(ffmpeg_output) do
      package_variant_once(package_context, tmp_dir, true)
    else
      {:error, reason}
    end
  end

  defp maybe_retry_package_variant_from_download(result, _package_context, _tmp_dir), do: result

  defp package_variant_once(package_context, tmp_dir, force_download?) do
    hls_dir_basename = if force_download?, do: "hls_download", else: "hls"

    with {:ok, input_path} <-
           download_input(
             package_context.storage_adapter,
             package_context.source_ref,
             package_context.region,
             tmp_dir,
             force_download: force_download?
           ) do
      package_variant_from_file(%{
        storage_adapter: package_context.storage_adapter,
        ffmpeg_bin: package_context.ffmpeg_bin,
        input_path: input_path,
        bucket: package_context.bucket,
        embed_hash: package_context.embed_hash,
        version: package_context.version,
        variant_dir: package_context.variant_dir,
        region: package_context.region,
        resolution: Map.get(package_context, :resolution),
        progress: package_context.progress,
        tmp_dir: tmp_dir,
        hls_dir_basename: hls_dir_basename
      })
    end
  end

  defp package_variant_from_file(package_context) do
    with {:ok, input_path} <- StepSupport.require_binary(package_context.input_path, :input_path),
         {:ok, hls_dir} <-
           prepare_hls_dir(package_context.tmp_dir, package_context.hls_dir_basename),
         :ok <-
           run_hls_ffmpeg(
             package_context.ffmpeg_bin,
             input_path,
             hls_dir,
             package_context.progress
           ),
         {:ok, files} <-
           upload_hls_dir(
             package_context.storage_adapter,
             package_context.bucket,
             hls_dir,
             package_context.embed_hash,
             package_context.version,
             package_context.variant_dir,
             package_context.region
           ) do
      playlist_key =
        base_prefix(package_context.embed_hash, package_context.version) <>
          package_context.variant_dir <> "/playlist.m3u8"

      {:ok,
       packaged_variant(
         files,
         playlist_key,
         package_context.bucket,
         package_context.variant_dir,
         Map.get(package_context, :resolution) || probe_video_resolution(input_path)
       )}
    end
  end

  defp packaged_variant(files, playlist_key, bucket, variant_dir, resolution) do
    total_size = Enum.reduce(files, 0, fn file, acc -> acc + file["file_size"] end)
    segment_count = Enum.count(files, &String.ends_with?(&1["name"], ".m4s"))

    %{
      files: files,
      total_size: total_size,
      segment_count: segment_count,
      bucket: bucket,
      playlist_key: playlist_key,
      playlist_uri: "s3://#{bucket}/#{playlist_key}",
      variant_dir: variant_dir,
      resolution: resolution
    }
  end

  defp probe_video_resolution(input_path) do
    with {:ok, ffprobe_bin} <- StepSupport.find_ffprobe(),
         {output, 0} <-
           StepSupport.run_media_cmd(ffprobe_bin, [
             "-v",
             "error",
             "-select_streams",
             "v:0",
             "-show_entries",
             "stream=width,height",
             "-of",
             "csv=s=x:p=0",
             input_path
           ]),
         resolution when resolution != "" <- String.trim(output) do
      resolution
    else
      _ -> nil
    end
  end

  defp download_input(_storage_adapter, source_ref, region, tmp_dir, opts) do
    case StepSupport.prepare_storage_ffmpeg_input(
           tmp_dir,
           source_ref.bucket,
           source_ref.key,
           region,
           "video/mp4",
           Map.get(source_ref, :uri),
           "mp4",
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

  defp run_hls_ffmpeg(ffmpeg_bin, input_path, hls_dir, progress) do
    report_hls_started(progress)

    segment_pattern = Path.join(hls_dir, "segment_%03d.m4s")
    playlist_path = Path.join(hls_dir, "playlist.m3u8")

    args = [
      "-hide_banner",
      "-nostats",
      "-progress",
      "pipe:1",
      "-loglevel",
      "error",
      "-y",
      "-i",
      input_path,
      "-map",
      "0:v:0",
      "-c:v",
      "copy",
      "-an",
      "-hls_time",
      "6",
      "-hls_playlist_type",
      "vod",
      "-hls_flags",
      "independent_segments",
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
    |> Task.async_stream(
      &upload_hls_file_with_name(&1, upload_context),
      max_concurrency: storage_object_max_concurrency(),
      ordered: true,
      timeout: :infinity
    )
    |> Enum.reduce_while({:ok, []}, &reduce_uploaded_hls_file/2)
  end

  defp upload_hls_file_with_name(file_name, upload_context) do
    local_path = Path.join(upload_context.hls_dir, file_name)

    result =
      upload_hls_file(
        upload_context.storage_adapter,
        upload_context.bucket,
        local_path,
        upload_context.embed_hash,
        upload_context.version,
        upload_context.variant_dir,
        file_name,
        upload_context.region
      )

    {file_name, result}
  end

  defp reduce_uploaded_hls_file({:ok, {_file_name, {:ok, uploaded}}}, {:ok, acc}) do
    {:cont, {:ok, [uploaded | acc]}}
  end

  defp reduce_uploaded_hls_file({:ok, {file_name, {:error, reason}}}, {:ok, _acc}) do
    {:halt, {:error, {:hls_upload_failed, file_name, reason}}}
  end

  defp reduce_uploaded_hls_file({:exit, reason}, {:ok, _acc}) do
    {:halt, {:error, {:hls_upload_failed, reason}}}
  end

  defp storage_object_max_concurrency do
    case Application.get_env(:mave_core, :storage_object_max_concurrency, 8) do
      value when is_integer(value) and value > 0 -> value
      _ -> 8
    end
  end

  defp build_variant_dir(codec, size, params) do
    case normalize_param(Map.get(params, "variant_dir"), nil) do
      nil ->
        {:ok, "#{codec}_#{size}_hls"}

      variant_dir ->
        {:ok, variant_dir}
    end
  end

  defp profile_for_size(size) do
    Map.get(@variant_profiles, size, %{bandwidth: nil, resolution: nil})
  end

  defp output_from_packaged(step_id, codec, size, packaged) do
    profile = profile_for_size(size)
    variant_dir = packaged.variant_dir
    playlist_relative_path = "#{variant_dir}/playlist.m3u8"

    rendition = %{
      "type" => "video",
      "size" => size,
      "codec" => codec,
      "container" => "hls",
      "progress" => 100.0,
      "rendition_key" => packaged.playlist_key,
      "src" => packaged.playlist_uri,
      "file_size" => packaged.total_size
    }

    %{
      "status" => "ok",
      "step_type" => "media.package_hls_variant",
      "step_id" => step_id,
      "codec" => codec,
      "size" => size,
      "container" => "hls",
      "bucket" => packaged.bucket,
      "variant_dir" => variant_dir,
      "bandwidth" => profile.bandwidth,
      "resolution" => packaged.resolution || profile.resolution,
      "playlist_key" => packaged.playlist_key,
      "playlist_uri" => packaged.playlist_uri,
      "playlist_path" => playlist_relative_path,
      "files" => packaged.files,
      "segment_count" => packaged.segment_count,
      "file_size" => packaged.total_size,
      "rendition" => rendition,
      "renditions" => [rendition]
    }
  end

  defp artifacts_from_output(output, space_hash, embed_hash, version) do
    [
      %{
        name: "#{output["variant_dir"]}_playlist",
        uri: output["playlist_uri"],
        media_type: "application/vnd.apple.mpegurl",
        size_bytes: playlist_size(output["files"]),
        metadata: %{
          "type" => "video",
          "container" => "hls",
          "codec" => output["codec"],
          "size" => output["size"],
          "space_hash" => space_hash,
          "embed_hash" => embed_hash,
          "version" => StepSupport.normalize_version(version)
        }
      }
    ]
  end

  defp prepackaged_hls_output?(video_output, codec, size) do
    hls_output = map_get(video_output, "hls")

    is_map(hls_output) and hls_output["status"] == "ok" and
      hls_output["step_type"] == "media.package_hls_variant" and
      output_matches_variant?(hls_output, codec, size)
  end

  defp normalize_prepackaged_output(output, step_id) do
    output
    |> Map.put("step_id", step_id)
    |> Map.put("mode", "prepackaged")
    |> Map.put("prepackaged", true)
  end

  defp playlist_size(files) do
    files
    |> Enum.find_value(fn file ->
      if file["name"] == "playlist.m3u8", do: file["file_size"], else: nil
    end)
  end

  defp ffmpeg_progress(nil, _step_id, _codec, _size, _video_output), do: nil

  defp ffmpeg_progress(progress_reporter, step_id, codec, size, video_output) do
    %{
      reporter: progress_reporter,
      stage: "package_hls",
      step_id: step_id,
      codec: codec,
      size: size,
      container: "hls",
      total_ms: video_duration_ms(video_output)
    }
  end

  defp report_hls_started(nil), do: :ok

  defp report_hls_started(progress) do
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

  defp video_duration_ms(video_output) do
    map_get(video_output, "duration_ms") ||
      video_output
      |> map_get("duration")
      |> duration_ms()
  end

  defp duration_ms(value) when is_integer(value), do: value * 1000
  defp duration_ms(value) when is_float(value), do: round(value * 1000)

  defp duration_ms(value) when is_binary(value) do
    case Float.parse(value) do
      {parsed, _rest} -> duration_ms(parsed)
      _ -> nil
    end
  end

  defp duration_ms(_value), do: nil

  defp hls_content_type(file_name) do
    cond do
      String.ends_with?(file_name, ".m3u8") -> "application/vnd.apple.mpegurl"
      String.ends_with?(file_name, ".m4s") -> "video/mp4"
      file_name == "init.mp4" -> "video/mp4"
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

  defp unavailable_output(step_id, codec, size, reason) do
    %{
      "status" => "unavailable",
      "step_type" => "media.package_hls_variant",
      "step_id" => step_id,
      "codec" => codec,
      "size" => size,
      "container" => "hls",
      "error" => inspect(reason)
    }
  end

  defp skipped_output(step_id, codec, size, reason) do
    %{
      "status" => "skipped",
      "step_type" => "media.package_hls_variant",
      "step_id" => step_id,
      "codec" => codec,
      "size" => size,
      "container" => "hls",
      "reason" => reason
    }
  end

  defp resolve_space_hash(video_output, source_output, run_input) do
    map_get(video_output, "space_hash") ||
      map_get(source_output, "space_hash") ||
      map_get(run_input, "space_hash")
  end

  defp resolve_embed_hash(video_output, source_output, run_input) do
    map_get(video_output, "embed_hash") ||
      map_get(source_output, "embed_hash") ||
      map_get(run_input, "embed_hash")
  end

  defp resolve_version(video_output, source_output, run_input) do
    map_get(video_output, "version") ||
      map_get(source_output, "version") ||
      map_get(run_input, "version", 0)
  end

  defp preferred_video_output(_dependency_outputs, nil), do: %{}

  defp preferred_video_output(dependency_outputs, preferred_step_id) do
    case Map.get(dependency_outputs, preferred_step_id) do
      %{} = output -> output
      _ -> %{}
    end
  end

  defp find_transcode_output(dependency_outputs, codec, size) do
    Enum.find_value(dependency_outputs, %{}, fn {_step_id, output} ->
      if ok_transcode_video_output?(output, codec, size), do: output, else: nil
    end) ||
      Enum.find_value(dependency_outputs, %{}, fn {_step_id, output} ->
        output
        |> ok_ladder_video_output?()
        |> select_ladder_output(output, codec, size)
      end) ||
      Enum.find_value(dependency_outputs, %{}, fn {_step_id, output} ->
        if skipped_transcode_video_output?(output), do: output, else: nil
      end) ||
      Enum.find_value(dependency_outputs, %{}, fn {_step_id, output} ->
        if skipped_ladder_video_output?(output), do: output, else: nil
      end)
  end

  defp select_variant_output(%{"step_type" => "media.transcode_waveform"} = output, codec, size) do
    if output_matches_variant?(output, codec, size), do: output, else: %{}
  end

  defp select_variant_output(output, codec, size) when is_map(output) do
    cond do
      ok_transcode_video_output?(output, codec, size) ->
        output

      ok_ladder_video_output?(output) ->
        select_ladder_output(true, output, codec, size)

      skipped_transcode_video_output?(output) or skipped_ladder_video_output?(output) ->
        output

      true ->
        %{}
    end
  end

  defp select_variant_output(_output, _codec, _size), do: %{}

  defp ok_transcode_video_output?(output, codec, size) do
    is_map(output) and output["step_type"] == "media.transcode_video" and
      output["status"] == "ok" and output_matches_variant?(output, codec, size)
  end

  defp output_matches_variant?(output, codec, size) do
    output_codec = normalize_param(map_get(output, "codec"), "h264")
    output_size = normalize_param(map_get(output, "size"), "sd")
    output_codec == codec and output_size == size
  end

  defp skipped_transcode_video_output?(output) do
    is_map(output) and output["step_type"] == "media.transcode_video" and
      output["status"] in ["skipped", "unavailable"]
  end

  defp ok_ladder_video_output?(output) do
    is_map(output) and output["step_type"] == "media.transcode_h264_ladder" and
      output["status"] == "ok"
  end

  defp skipped_ladder_video_output?(output) do
    is_map(output) and output["step_type"] == "media.transcode_h264_ladder" and
      output["status"] in ["skipped", "unavailable"]
  end

  defp select_ladder_output(true, output, codec, size) do
    output
    |> ladder_variant_output(size)
    |> case do
      %{} = variant when map_size(variant) > 0 ->
        if output_matches_variant?(variant, codec, size) do
          inherit_ladder_context(variant, output)
        end

      _ ->
        nil
    end
  end

  defp select_ladder_output(_ok?, _output, _codec, _size), do: nil

  defp ladder_variant_output(output, size) do
    case map_get(output, "variant_outputs", %{}) do
      %{} = variant_outputs ->
        case map_get(variant_outputs, size) do
          %{} = variant -> variant
          _ -> ladder_variant_from_list(output, size)
        end

      _ ->
        ladder_variant_from_list(output, size)
    end
  end

  defp ladder_variant_from_list(output, size) do
    output
    |> map_get("variants", [])
    |> Enum.find(%{}, fn
      %{} = variant -> normalize_param(map_get(variant, "size"), nil) == size
      _ -> false
    end)
  end

  defp inherit_ladder_context(variant, output) do
    variant
    |> Map.put_new("space_hash", map_get(output, "space_hash"))
    |> Map.put_new("embed_hash", map_get(output, "embed_hash"))
    |> Map.put_new("version", map_get(output, "version"))
    |> Map.put_new("bucket", map_get(output, "bucket"))
  end

  defp upload_hls_file(
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
         {:ok, key} <- build_uploaded_hls_key(embed_hash, version, variant_dir, file_name),
         content_type = hls_content_type(file_name),
         :ok <-
           put_hls_file(
             storage_adapter,
             bucket,
             key,
             local_path,
             content_type,
             region,
             size
           ) do
      {:ok, uploaded_hls_file(file_name, key, bucket, size, content_type)}
    end
  end

  defp put_hls_file(storage_adapter, bucket, key, local_path, content_type, region, size) do
    case storage_adapter.put_file_public(bucket, key, local_path, content_type, region) do
      {:ok, _body} ->
        :ok

      {:error, reason} ->
        if uploaded_file_matches?(storage_adapter, bucket, key, region, size),
          do: :ok,
          else: {:error, reason}
    end
  end

  defp uploaded_file_matches?(storage_adapter, bucket, key, region, expected_size) do
    if function_exported?(storage_adapter, :object_info, 3) do
      case storage_adapter.object_info(bucket, key, region) do
        {:ok, %{size_bytes: ^expected_size}} -> true
        _other -> false
      end
    else
      false
    end
  end

  defp uploaded_hls_file(file_name, key, bucket, size, content_type) do
    %{
      "name" => file_name,
      "key" => key,
      "uri" => "s3://#{bucket}/#{key}",
      "file_size" => size,
      "content_type" => content_type
    }
  end

  defp build_uploaded_hls_key(embed_hash, version, variant_dir, file_name) do
    {:ok, base_prefix(embed_hash, version) <> variant_dir <> "/" <> file_name}
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

  defp map_atom_string_value(map, map_key, key) when is_atom(map_key) do
    if Atom.to_string(map_key) == key, do: Map.get(map, map_key), else: nil
  end

  defp map_atom_string_value(_map, _map_key, _key), do: nil

  defp normalize_param(nil, default), do: default
  defp normalize_param(value, _default) when is_binary(value) and value != "", do: value
  defp normalize_param(value, _default) when is_atom(value), do: Atom.to_string(value)
  defp normalize_param(_value, default), do: default

  defp truncate(value, max) when is_binary(value) and is_integer(max) and max > 3 do
    if String.length(value) <= max do
      value
    else
      String.slice(value, 0, max - 3) <> "..."
    end
  end

  defp truncate(value, _max), do: inspect(value)
end
