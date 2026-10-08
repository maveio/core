defmodule MaveCore.Flow.Steps.MediaInspectStep do
  @moduledoc """
  Extracts source media metadata using ffprobe.

  For deterministic tests and offline runs, `run_input["media_probe"]` can be
  provided to bypass ffprobe and return explicit metadata.
  """
  @behaviour MaveCore.Flow.Step

  alias MaveCore.Flow.Steps.Support, as: StepSupport
  alias MaveCore.Media.RemoteSource
  alias MaveCore.Media.Signature
  alias MaveCore.Media.Storage

  @safe_input_formats "aac,aiff,amr,avi,flac,flv,matroska,webm,mov,mp3,mpeg,mpegts,mpegvideo,ogg,wav"

  @impl true
  def run(step_definition, context) do
    run_input = Map.get(context, :run_input, %{})
    params = Map.get(step_definition, "params", %{})
    dependency_outputs = Map.get(context, :dependency_outputs, %{})
    source_output = Map.get(dependency_outputs, "source", %{})
    upload_output = Map.get(dependency_outputs, "upload_original", %{})

    source_url =
      Map.get(run_input, "upload_ffmpeg_input_url") ||
        uploaded_original_source(upload_output) ||
        Map.get(source_output, "source_url") ||
        Map.get(run_input, "input_url")

    source_content_type =
      Map.get(upload_output, "content_type") || Map.get(run_input, "source_content_type")

    strict? = StepSupport.strict_enabled?(params, run_input, "media_inspect_strict")

    case resolve_probe_payload(run_input, source_url, source_content_type, upload_output) do
      {:ok, payload} ->
        {:ok, build_output(payload, run_input, source_url), []}

      {:error, reason} when strict? ->
        cleanup_invalid_uploaded_original(reason, upload_output, run_input)
        {:error, {:media_inspect_failed, reason}}

      {:error, reason} ->
        {:ok, unavailable_output(reason, run_input, source_url), []}
    end
  end

  defp resolve_probe_payload(run_input, source_url, source_content_type, upload_output) do
    case Map.get(run_input, "media_probe") do
      %{} = probe ->
        {:ok, probe}

      nil ->
        inspect_source(run_input, source_url, source_content_type, upload_output)

      _other ->
        {:error, {:invalid_field, :media_probe}}
    end
  end

  defp inspect_source(run_input, source_url, source_content_type, upload_output) do
    case Map.get(run_input, "upload_ffmpeg_input_url") do
      input_url when is_binary(input_url) and input_url != "" ->
        case validate_direct_probe_signature(run_input, upload_output) do
          :ok ->
            inspect_direct_probe(
              input_url,
              run_input,
              source_url,
              source_content_type,
              upload_output
            )

          :download ->
            inspect_source_from_storage(run_input, source_url, source_content_type, upload_output)

          {:error, reason} ->
            {:error, reason}
        end

      _other ->
        inspect_source_from_storage(run_input, source_url, source_content_type, upload_output)
    end
  end

  defp inspect_direct_probe(input_url, run_input, source_url, source_content_type, upload_output) do
    case run_ffprobe(input_url) do
      {:ok, payload} ->
        {:ok, payload}

      {:error, _reason} ->
        inspect_source_from_storage(run_input, source_url, source_content_type, upload_output)
    end
  end

  defp validate_direct_probe_signature(run_input, upload_output) do
    case uploaded_original_storage_reference(upload_output, run_input) do
      {:ok, storage_adapter, bucket, key, region} ->
        validate_storage_media_signature(storage_adapter, bucket, key, region)

      :error ->
        case StepSupport.source_storage_reference(run_input) do
          {:ok, bucket, key, region} ->
            storage_adapter = Application.get_env(:mave_core, :flow_storage_adapter, Storage)
            validate_storage_media_signature(storage_adapter, bucket, key, region)

          :error ->
            :download
        end
    end
  end

  defp uploaded_original_storage_reference(upload_output, run_input) do
    bucket = Map.get(upload_output, "bucket")
    key = Map.get(upload_output, "original_key")
    region = Map.get(run_input, "region")

    if is_binary(bucket) and bucket != "" and is_binary(key) and key != "" do
      storage_adapter = Application.get_env(:mave_core, :flow_storage_adapter, Storage)
      {:ok, storage_adapter, bucket, key, region}
    else
      :error
    end
  end

  defp inspect_source_from_storage(run_input, source_url, source_content_type, upload_output) do
    case inspect_uploaded_original(upload_output, run_input, source_content_type) do
      {:ok, payload} ->
        {:ok, payload}

      :no_uploaded_original ->
        inspect_resolved_source(run_input, source_url, source_content_type)

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp inspect_resolved_source(run_input, source_url, source_content_type) do
    case Map.fetch(run_input, "source_body") do
      {:ok, body} when is_binary(body) ->
        inspect_inline_body(body, source_content_type)

      {:ok, _other} ->
        {:error, {:invalid_field, :source_body}}

      :error ->
        case StepSupport.source_storage_reference(run_input) do
          {:ok, bucket, key, region} ->
            inspect_storage_object(bucket, key, region, source_content_type, source_url)

          :error ->
            inspect_remote_fallback(run_input, source_url, source_content_type)
        end
    end
  end

  defp inspect_remote_fallback(%{"durable_source_required" => true}, _source_url, _content_type),
    do: {:error, :durable_media_source_required}

  defp inspect_remote_fallback(_run_input, source_url, content_type),
    do: inspect_remote_source(source_url, content_type)

  defp inspect_uploaded_original(upload_output, run_input, source_content_type) do
    bucket = Map.get(upload_output, "bucket")
    key = Map.get(upload_output, "original_key")
    region = Map.get(run_input, "region")

    if is_binary(bucket) and bucket != "" and is_binary(key) and key != "" do
      inspect_storage_object(
        bucket,
        key,
        region,
        Map.get(upload_output, "content_type") || source_content_type,
        Map.get(upload_output, "original_uri")
      )
      |> case do
        {:error, reason} -> {:error, {:uploaded_original_get_failed, reason}}
        other -> other
      end
    else
      :no_uploaded_original
    end
  end

  defp uploaded_original_source(upload_output) when is_map(upload_output) do
    Map.get(upload_output, "original_uri")
  end

  defp uploaded_original_source(_), do: nil

  defp inspect_inline_body(body, content_type) do
    extension = StepSupport.extension_from_content_type(content_type) || "bin"

    StepSupport.with_temp_dir("probe", fn tmp_dir ->
      with {:ok, tmp_path} <- StepSupport.tmp_file_path(tmp_dir, "input", extension),
           :ok <- StepSupport.write_tmp_file(tmp_path, body),
           :ok <- Signature.validate_audio_or_video(body),
           {:ok, payload} <- run_ffprobe(tmp_path) do
        payload =
          payload
          |> Map.put_new("filetype", extension)
          |> Map.put_new("size_bytes", byte_size(body))

        {:ok, payload}
      else
        {:error, reason} -> {:error, reason}
        reason -> {:error, reason}
      end
    end)
  end

  defp inspect_storage_object(bucket, key, region, content_type, source_url) do
    storage_adapter = Application.get_env(:mave_core, :flow_storage_adapter, Storage)
    extension = probe_extension(content_type, source_url)

    case validate_storage_media_signature(storage_adapter, bucket, key, region) do
      :ok ->
        inspect_validated_storage_object(
          storage_adapter,
          bucket,
          key,
          region,
          extension
        )

      :download ->
        inspect_downloaded_storage_object(
          storage_adapter,
          bucket,
          key,
          region,
          extension
        )

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp validate_storage_media_signature(storage_adapter, bucket, key, region) do
    if function_exported?(storage_adapter, :get_prefix, 4) do
      case storage_adapter.get_prefix(bucket, key, region, Signature.probe_bytes_limit()) do
        {:ok, prefix} -> Signature.validate_audio_or_video(prefix)
        {:error, _reason} -> :download
      end
    else
      :download
    end
  end

  defp inspect_validated_storage_object(storage_adapter, bucket, key, region, extension) do
    case storage_probe_input_url(storage_adapter, bucket, key, region) do
      {:ok, input_url} ->
        with {:ok, payload} <- run_ffprobe(input_url) do
          {:ok, Map.put_new(payload, "filetype", extension)}
        end

      :download ->
        inspect_downloaded_storage_object(storage_adapter, bucket, key, region, extension)

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp storage_probe_input_url(storage_adapter, bucket, key, region) do
    presigned_url =
      if function_exported?(storage_adapter, :presigned_get_url, 4) do
        storage_adapter.presigned_get_url(bucket, key, region, expires: 15 * 60)
        |> normalize_storage_input_url()
      else
        {:error, :unsupported}
      end

    case presigned_url do
      {:ok, _url} = result -> result
      {:error, _reason} -> storage_ffmpeg_input_url(storage_adapter, bucket, key, region)
    end
  end

  defp storage_ffmpeg_input_url(storage_adapter, bucket, key, region) do
    if function_exported?(storage_adapter, :ffmpeg_input_url, 3) do
      storage_adapter.ffmpeg_input_url(bucket, key, region)
      |> normalize_storage_input_url()
    else
      :download
    end
  end

  defp normalize_storage_input_url({:ok, url}), do: normalize_storage_input_url(url)
  defp normalize_storage_input_url({:error, reason}), do: {:error, reason}

  defp normalize_storage_input_url(url) when is_binary(url) do
    if String.trim(url) == "", do: {:error, :empty_url}, else: {:ok, url}
  end

  defp normalize_storage_input_url(_url), do: {:error, :invalid_url}

  defp inspect_downloaded_storage_object(storage_adapter, bucket, key, region, extension) do
    with_temp_path(extension, fn tmp_path ->
      with :ok <- download_storage_object(storage_adapter, bucket, key, tmp_path, region),
           :ok <- Signature.validate_audio_or_video_file(tmp_path),
           {:ok, payload} <- run_ffprobe(tmp_path) do
        payload =
          payload
          |> Map.put_new("filetype", extension)
          |> maybe_put_size(file_size_for(tmp_path))

        {:ok, payload}
      end
    end)
  end

  defp inspect_remote_source(source_url, content_type)
       when is_binary(source_url) and source_url != "" do
    extension = probe_extension(content_type, source_url)

    with_temp_path(extension, fn tmp_path ->
      with {:ok, _download} <- RemoteSource.download_to_file(source_url, tmp_path),
           :ok <- Signature.validate_audio_or_video_file(tmp_path),
           {:ok, payload} <- run_ffprobe(tmp_path) do
        payload =
          payload
          |> Map.put_new("filetype", extension)
          |> maybe_put_size(file_size_for(tmp_path))

        {:ok, payload}
      end
    end)
  end

  defp inspect_remote_source(_source_url, _content_type),
    do: {:error, {:missing_field, :source_url}}

  defp cleanup_invalid_uploaded_original(reason, upload_output, run_input) do
    if invalid_uploaded_original?(reason) do
      delete_uploaded_original(upload_output, run_input)
    end
  end

  defp invalid_uploaded_original?({:uploaded_original_get_failed, :unsupported_media_signature}),
    do: true

  defp invalid_uploaded_original?(
         {:uploaded_original_get_failed, {:ffprobe_exit, _status, _body}}
       ),
       do: true

  defp invalid_uploaded_original?({:uploaded_original_get_failed, :invalid_probe_output}),
    do: true

  defp invalid_uploaded_original?(
         {:uploaded_original_get_failed, {:invalid_probe_json, _reason}}
       ),
       do: true

  defp invalid_uploaded_original?(_reason), do: false

  defp delete_uploaded_original(upload_output, run_input) do
    bucket = Map.get(upload_output, "bucket")
    key = Map.get(upload_output, "original_key")
    region = Map.get(run_input, "region")
    storage_adapter = Application.get_env(:mave_core, :flow_storage_adapter, Storage)

    if is_binary(bucket) and bucket != "" and is_binary(key) and key != "" and
         function_exported?(storage_adapter, :delete_object, 3) do
      _ = storage_adapter.delete_object(bucket, key, region)
    end

    :ok
  end

  defp with_temp_path(extension, fun) when is_binary(extension) and is_function(fun, 1) do
    StepSupport.with_temp_dir("probe", fn tmp_dir ->
      with {:ok, tmp_path} <- StepSupport.tmp_file_path(tmp_dir, "input", extension) do
        fun.(tmp_path)
      end
    end)
  end

  defp file_size_for(path) do
    case File.stat(path) do
      {:ok, %File.Stat{size: size}} -> size
      _ -> nil
    end
  end

  defp maybe_put_size(payload, size) when is_integer(size),
    do: Map.put_new(payload, "size_bytes", size)

  defp maybe_put_size(payload, _size), do: payload

  defp probe_extension(content_type, source_url) do
    StepSupport.extension_from_content_type(content_type) ||
      StepSupport.extension_from_url(source_url) ||
      "bin"
  end

  defp download_storage_object(storage_adapter, bucket, key, tmp_path, region) do
    if function_exported?(storage_adapter, :download_to_file, 4) do
      storage_adapter.download_to_file(bucket, key, tmp_path, region)
    else
      copy_storage_object_to_file(storage_adapter, bucket, key, tmp_path, region)
    end
  end

  defp copy_storage_object_to_file(storage_adapter, bucket, key, tmp_path, region) do
    with {:ok, body} <- storage_adapter.get(bucket, key, region),
         :ok <- ensure_binary_body(body, :storage),
         :ok <- StepSupport.write_tmp_file(tmp_path, body) do
      :ok
    else
      {:error, reason} -> {:error, reason}
    end
  end

  defp ensure_binary_body(body, _source) when is_binary(body), do: :ok
  defp ensure_binary_body(_body, source), do: {:error, {:invalid_source_body, source}}

  defp run_ffprobe(input) do
    case StepSupport.find_ffprobe() do
      {:error, :ffprobe_not_found} ->
        {:error, :ffprobe_not_found}

      {:ok, ffprobe} ->
        args = [
          "-v",
          "error",
          "-format_whitelist",
          @safe_input_formats,
          "-print_format",
          "json",
          "-show_streams",
          "-show_format",
          input
        ]

        case StepSupport.run_media_cmd(ffprobe, args) do
          {output, 0} ->
            decode_probe_output(output)

          {output, status} ->
            {:error, {:ffprobe_exit, status, String.trim(output)}}
        end
    end
  end

  @doc false
  def decode_probe_output(output) do
    case StepSupport.decode_probe_output(output) do
      {:ok, payload} ->
        {:ok, payload}

      {:error, :invalid_probe_output} ->
        {:error, :invalid_probe_output}

      {:error, reason} ->
        {:error, {:invalid_probe_json, reason}}
    end
  end

  defp build_output(payload, run_input, source_url) do
    format = map_get(payload, "format", %{})
    streams = map_get(payload, "streams", [])
    video_stream = StepSupport.video_stream(streams)
    audio_stream = Enum.find(streams, fn stream -> map_get(stream, "codec_type") == "audio" end)
    {width, height} = inspect_dimensions(video_stream)
    format_duration = inspect_duration(payload, format)
    format_size = inspect_size(payload, format)
    format_name = inspect_format_name(payload, format)
    aspect_ratio = inspect_aspect_ratio(payload, video_stream, width, height)
    filetype = inspect_filetype(payload, run_input, source_url, format_name)

    %{
      "status" => "ok",
      "step_type" => "media.inspect",
      "source" => source_url,
      "duration" => format_duration,
      "size_bytes" => format_size,
      "filetype" => filetype,
      "aspect_ratio" => aspect_ratio,
      "width" => width,
      "height" => height,
      "video_codec" => map_get(video_stream, "codec_name"),
      "audio_codec" => map_get(audio_stream, "codec_name"),
      "has_video" => not is_nil(video_stream),
      "has_audio" => not is_nil(audio_stream),
      "format_name" => first_format(map_get(format, "format_name")),
      "streams" => streams
    }
    |> Map.merge(extract_passthrough_fields(payload))
  end

  defp extract_passthrough_fields(payload) do
    payload
    |> Enum.filter(fn {key, _value} ->
      key in [
        "video_id",
        "name",
        "metrics_key"
      ]
    end)
    |> Map.new()
  end

  defp unavailable_output(reason, run_input, source_url) do
    filetype =
      map_get(run_input, "filetype") ||
        StepSupport.extension_from_content_type(map_get(run_input, "source_content_type")) ||
        StepSupport.extension_from_url(source_url)

    %{
      "status" => "unavailable",
      "step_type" => "media.inspect",
      "source" => source_url,
      "duration" => parse_float(map_get(run_input, "duration")),
      "size_bytes" => parse_integer(map_get(run_input, "size")),
      "filetype" => filetype,
      "aspect_ratio" => map_get(run_input, "aspect_ratio"),
      "video_codec" => nil,
      "audio_codec" => nil,
      "has_video" => nil,
      "has_audio" => nil,
      "streams" => [],
      "error" => inspect(reason)
    }
  end

  defp inspect_dimensions(video_stream) do
    {
      parse_integer(map_get(video_stream, "width")),
      parse_integer(map_get(video_stream, "height"))
    }
  end

  defp inspect_duration(payload, format) do
    parse_float(map_get(payload, "duration")) ||
      parse_float(map_get(format, "duration"))
  end

  defp inspect_size(payload, format) do
    parse_integer(map_get(payload, "size_bytes")) ||
      parse_integer(map_get(payload, "size")) ||
      parse_integer(map_get(format, "size"))
  end

  defp inspect_format_name(payload, format) do
    map_get(payload, "filetype") ||
      first_format(map_get(payload, "format_name")) ||
      first_format(map_get(format, "format_name"))
  end

  defp inspect_aspect_ratio(payload, video_stream, width, height) do
    map_get(payload, "aspect_ratio") ||
      aspect_ratio_from_stream(video_stream, width, height)
  end

  defp inspect_filetype(payload, run_input, source_url, format_name) do
    map_get(payload, "filetype") ||
      map_get(run_input, "filetype") ||
      StepSupport.extension_from_url(source_url) ||
      format_name
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

  defp first_format(nil), do: nil

  defp first_format(value) when is_binary(value) do
    value
    |> String.split(",")
    |> List.first()
    |> String.trim()
  end

  defp first_format(_), do: nil

  defp aspect_ratio_from_stream(video_stream, _width, _height) do
    case map_get(video_stream, "display_aspect_ratio") do
      ratio when is_binary(ratio) and ratio != "" and ratio != "0:1" and ratio != "N/A" ->
        String.replace(ratio, ":", " / ")

      _ ->
        "16 / 9"
    end
  end

  defp parse_float(nil), do: nil
  defp parse_float(value) when is_float(value), do: value
  defp parse_float(value) when is_integer(value), do: value * 1.0

  defp parse_float(value) when is_binary(value) do
    case Float.parse(value) do
      {parsed, _rest} -> parsed
      :error -> nil
    end
  end

  defp parse_float(_), do: nil

  defp parse_integer(nil), do: nil
  defp parse_integer(value) when is_integer(value), do: value

  defp parse_integer(value) when is_binary(value) do
    case Integer.parse(value) do
      {parsed, _rest} -> parsed
      :error -> nil
    end
  end

  defp parse_integer(_), do: nil
end
