defmodule MaveCore.Flow.Steps.AssetUploadOriginalStep do
  @moduledoc """
  Uploads the original source file and player HTML shell to object storage.
  """
  @behaviour MaveCore.Flow.Step

  alias MaveCore.Embeds.PlayerPublisher
  alias MaveCore.Flow.Steps.Support, as: StepSupport
  alias MaveCore.Media.ContentType
  alias MaveCore.Media.RemoteSource
  alias MaveCore.Media.Storage
  alias MaveCore.StorageProfiles

  @impl true
  def run(_step_definition, context) do
    run_input = Map.get(context, :run_input, %{})
    upstream = Map.get(context, :dependency_outputs, %{})

    upload_context = build_upload_context(run_input, upstream)

    with {:ok, space_hash} <- StepSupport.require_binary(upload_context.space_hash, :space_hash),
         {:ok, embed_hash} <- StepSupport.require_binary(upload_context.embed_hash, :embed_hash),
         {:ok, original_key} <- build_original_key(embed_hash, upload_context.version),
         {:ok, upload_result} <- upload_original(upload_context, original_key),
         {:ok, player_output} <-
           PlayerPublisher.publish(
             upload_context.storage_adapter,
             upload_context.bucket,
             space_hash,
             embed_hash,
             upload_context.version,
             upload_context.region
           ) do
      output = upload_output(upload_context.bucket, original_key, player_output, upload_result)

      artifacts =
        upload_artifacts(
          output,
          upload_context.source_url,
          space_hash,
          embed_hash,
          upload_context.version
        )

      {:ok, output, artifacts}
    else
      {:error, reason} ->
        {:error, reason}

      other ->
        {:error, {:upload_original_failed, other}}
    end
  end

  defp build_upload_context(run_input, upstream) do
    source = Map.get(upstream, "source", %{})
    bucket_info = Map.get(upstream, "ensure_bucket", %{})
    region = Map.get(run_input, "region")
    source_attrs = source_upload_attrs(source, run_input, region)

    %{
      run_input: run_input,
      bucket:
        Map.get(bucket_info, "bucket") ||
          Storage.bucket_for_space(source_attrs.space_hash, region),
      source_url: source_attrs.source_url,
      source_bucket: source_attrs.source_bucket,
      source_key: source_attrs.source_key,
      space_hash: source_attrs.space_hash,
      embed_hash: source_attrs.embed_hash,
      version: source_attrs.version,
      region: region,
      source_region: source_attrs.source_region,
      source_content_type: source_attrs.source_content_type,
      storage_adapter: Application.get_env(:mave_core, :flow_storage_adapter, Storage)
    }
  end

  defp source_upload_attrs(source, run_input, region) do
    %{
      source_url: source_url_attr(source, run_input),
      source_bucket: source_attr(source, run_input, "source_bucket"),
      source_key: source_attr(source, run_input, "source_key"),
      space_hash: source_attr(source, run_input, "space_hash"),
      embed_hash: source_attr(source, run_input, "embed_hash"),
      version: source_version(source, run_input),
      source_region: source_region(source, run_input, region),
      source_content_type: source_attr(source, run_input, "source_content_type")
    }
  end

  defp source_url_attr(source, run_input) do
    Map.get(source, "source_url") || Map.get(run_input, "input_url") ||
      Map.get(run_input, "source_url")
  end

  defp source_attr(source, run_input, key) do
    Map.get(source, key) || Map.get(run_input, key)
  end

  defp source_version(source, run_input) do
    Map.get(source, "version") || Map.get(run_input, "version", 0)
  end

  defp source_region(source, run_input, region) do
    Map.get(source, "source_region") || Map.get(run_input, "source_region") || region
  end

  defp upload_original(upload_context, original_key) do
    case Map.fetch(upload_context.run_input, "source_body") do
      {:ok, source_body} when is_binary(source_body) ->
        content_type =
          normalize_content_type(Map.get(upload_context.run_input, "source_content_type"))

        with :ok <-
               put_object(
                 upload_context.storage_adapter,
                 upload_context.bucket,
                 original_key,
                 source_body,
                 content_type,
                 upload_context.region
               ) do
          {:ok, %{bytes: byte_size(source_body), content_type: content_type}}
        end

      {:ok, _other} ->
        {:error, {:invalid_field, :source_body}}

      :error ->
        upload_source_reference(upload_context, original_key)
    end
  end

  defp upload_source_reference(upload_context, original_key) do
    if storage_source_reference?(upload_context.source_bucket, upload_context.source_key) do
      upload_source_from_storage(upload_context, original_key)
    else
      upload_source_from_url(upload_context, original_key)
    end
  end

  defp upload_source_from_storage(upload_context, original_key) do
    # Storage copies retain the source's HTTP metadata; only use the fast path
    # when that metadata is already safe for an original media object.
    case upload_context.storage_adapter.object_info(
           upload_context.source_bucket,
           upload_context.source_key,
           upload_context.source_region
         ) do
      {:ok, info} ->
        source_type = info[:content_type] || info["content_type"]

        if is_binary(source_type) and source_type == ContentType.media(source_type) do
          copy_source_from_storage(upload_context, original_key)
        else
          upload_source_via_download(
            upload_context,
            original_key,
            normalize_content_type(source_type)
          )
        end

      {:error, reason} ->
        {:error, {:original_info_failed, reason}}
    end
  end

  defp upload_source_via_download(context, original_key, content_type) do
    with_temp_path(content_type, fn tmp_path ->
      upload_downloaded_source_file(context, original_key, tmp_path, content_type)
    end)
  end

  defp copy_source_from_storage(upload_context, original_key) do
    cond do
      can_copy_within_profile?(
        upload_context.source_region,
        upload_context.region,
        upload_context.storage_adapter
      ) ->
        upload_source_via_storage_copy(upload_context, original_key)

      can_copy_between_profiles?(upload_context.storage_adapter) ->
        upload_source_via_profile_transfer(upload_context, original_key)

      true ->
        content_type = normalize_content_type(upload_context.source_content_type)

        with_temp_path(content_type, fn tmp_path ->
          upload_downloaded_source_file(upload_context, original_key, tmp_path, content_type)
        end)
    end
  end

  defp upload_source_via_storage_copy(upload_context, original_key) do
    with :ok <-
           copy_object(
             upload_context.storage_adapter,
             upload_context.bucket,
             original_key,
             upload_context.source_bucket,
             upload_context.source_key,
             upload_context.region
           ),
         {:ok, %{size_bytes: bytes, content_type: content_type}} <-
           fetch_object_info(
             upload_context.storage_adapter,
             upload_context.bucket,
             original_key,
             upload_context.region,
             upload_context.source_content_type
           ) do
      {:ok, %{bytes: bytes, content_type: content_type}}
    end
  end

  defp upload_source_via_profile_transfer(upload_context, original_key) do
    with :ok <-
           copy_object_between_profiles(
             upload_context.storage_adapter,
             upload_context.bucket,
             original_key,
             upload_context.region,
             upload_context.source_bucket,
             upload_context.source_key,
             upload_context.source_region
           ),
         {:ok, %{size_bytes: bytes, content_type: content_type}} <-
           fetch_object_info(
             upload_context.storage_adapter,
             upload_context.bucket,
             original_key,
             upload_context.region,
             upload_context.source_content_type
           ) do
      {:ok, %{bytes: bytes, content_type: content_type}}
    end
  end

  defp upload_source_from_url(%{source_url: source_url} = context, original_key)
       when is_binary(source_url) and source_url != "" do
    upload_remote_source_via_temp_file(context, original_key)
  end

  defp upload_source_from_url(_, _), do: {:error, {:missing_field, :source_url}}

  defp upload_remote_source_via_temp_file(context, original_key) do
    with_temp_path(
      normalize_content_type(context.source_content_type),
      fn tmp_path ->
        with {:ok, download} <- RemoteSource.download_to_file(context.source_url, tmp_path),
             content_type <- extract_content_type(download.headers, context.source_content_type),
             {:ok, bytes} <-
               upload_file(
                 context.storage_adapter,
                 context.bucket,
                 original_key,
                 tmp_path,
                 content_type,
                 context.region
               ) do
          {:ok, %{bytes: bytes, content_type: content_type}}
        end
      end
    )
  end

  defp upload_downloaded_source_file(upload_context, original_key, tmp_path, content_type) do
    with :ok <-
           download_source_to_file(
             upload_context.storage_adapter,
             upload_context.source_bucket,
             upload_context.source_key,
             tmp_path,
             upload_context.source_region
           ),
         {:ok, bytes} <-
           upload_file(
             upload_context.storage_adapter,
             upload_context.bucket,
             original_key,
             tmp_path,
             content_type,
             upload_context.region
           ) do
      {:ok, %{bytes: bytes, content_type: content_type}}
    end
  end

  defp put_object(storage_adapter, bucket, key, body, content_type, region) do
    case storage_adapter.put_public(bucket, key, body, content_type, region) do
      {:ok, _body} -> :ok
      {:error, reason} -> {:error, {:original_upload_failed, reason}}
    end
  end

  defp upload_file(storage_adapter, bucket, key, source_path, content_type, region) do
    with {:ok, %{size: size}} <- MaveCore.SafeFile.stat_regular(source_path),
         {:ok, _body} <-
           storage_adapter.put_file_public(bucket, key, source_path, content_type, region) do
      {:ok, size}
    else
      {:error, reason} -> {:error, {:original_upload_failed, reason}}
    end
  end

  defp copy_object(storage_adapter, bucket, key, source_bucket, source_key, region) do
    case storage_adapter.copy_public(bucket, key, source_bucket, source_key, region) do
      :ok -> :ok
      {:error, reason} -> {:error, {:original_upload_failed, reason}}
    end
  end

  defp copy_object_between_profiles(
         storage_adapter,
         bucket,
         key,
         region,
         source_bucket,
         source_key,
         source_region
       ) do
    case storage_adapter.copy_public_between_profiles(
           bucket,
           key,
           region,
           source_bucket,
           source_key,
           source_region
         ) do
      :ok -> :ok
      {:error, reason} -> {:error, {:original_upload_failed, reason}}
    end
  end

  defp fetch_object_info(storage_adapter, bucket, key, region, fallback_content_type) do
    case storage_adapter.object_info(bucket, key, region) do
      {:ok, info} ->
        raw_content_type = info[:content_type] || info["content_type"]

        content_type =
          raw_content_type
          |> normalize_content_type()
          |> content_type_or_fallback(fallback_content_type)

        {:ok,
         %{
           size_bytes: info[:size_bytes] || info["size_bytes"],
           content_type: content_type
         }}

      {:error, reason} ->
        {:error, {:original_info_failed, reason}}
    end
  end

  defp download_source_to_file(
         storage_adapter,
         source_bucket,
         source_key,
         tmp_path,
         source_region
       ) do
    case storage_adapter.download_to_file(source_bucket, source_key, tmp_path, source_region) do
      :ok -> :ok
      {:error, reason} -> {:error, {:source_storage_get_failed, reason}}
    end
  end

  defp can_copy_within_profile?(source_region, destination_region, storage_adapter) do
    function_exported?(storage_adapter, :copy_public, 5) and
      StorageProfiles.resolve(source_region) == StorageProfiles.resolve(destination_region) and
      not is_nil(destination_region)
  end

  defp can_copy_between_profiles?(storage_adapter) do
    function_exported?(storage_adapter, :copy_public_between_profiles, 6)
  end

  defp storage_source_reference?(source_bucket, source_key) do
    is_binary(source_bucket) and source_bucket != "" and is_binary(source_key) and
      source_key != ""
  end

  defp with_temp_path(extension_or_content_type, fun) when is_function(fun, 1) do
    extension =
      StepSupport.extension_from_content_type(extension_or_content_type) ||
        normalize_extension(extension_or_content_type) || "bin"

    StepSupport.with_temp_dir("upload_original", fn tmp_dir ->
      with {:ok, tmp_path} <- StepSupport.tmp_file_path(tmp_dir, "source", extension) do
        fun.(tmp_path)
      end
    end)
  end

  defp normalize_extension(value) when is_binary(value) and value != "" do
    value
    |> String.trim()
    |> String.trim_leading(".")
    |> case do
      "" -> nil
      normalized -> normalized
    end
  end

  defp normalize_extension(_), do: nil

  defp content_type_or_fallback(nil, fallback_content_type) do
    normalize_content_type(fallback_content_type)
  end

  defp content_type_or_fallback("application/octet-stream", fallback_content_type) do
    normalize_content_type(fallback_content_type) || "application/octet-stream"
  end

  defp content_type_or_fallback(content_type, _fallback_content_type), do: content_type

  defp extract_content_type(headers, fallback) do
    headers
    |> extract_content_type()
    |> case do
      "application/octet-stream" -> normalize_content_type(fallback)
      content_type -> content_type
    end
  end

  defp extract_content_type(headers) when is_map(headers) do
    headers
    |> Enum.to_list()
    |> extract_content_type()
  end

  defp extract_content_type(headers) when is_list(headers) do
    headers
    |> Enum.find_value(fn
      {"content-type", value} -> value
      {"Content-Type", value} -> value
      {:content_type, value} -> value
      {"content_type", value} -> value
      _ -> nil
    end)
    |> normalize_content_type()
  end

  defp extract_content_type(_), do: "application/octet-stream"

  defp normalize_content_type(nil), do: "application/octet-stream"

  defp normalize_content_type(value) when is_binary(value) do
    value
    |> String.split(";")
    |> List.first()
    |> String.trim()
    |> case do
      "" -> "application/octet-stream"
      content_type -> ContentType.media(content_type)
    end
  end

  defp normalize_content_type(values) when is_list(values) do
    if Enum.all?(values, fn item -> is_integer(item) end) do
      values
      |> List.to_string()
      |> normalize_content_type()
    else
      values
      |> find_content_type_value()
      |> normalize_content_type()
    end
  end

  defp normalize_content_type(_), do: "application/octet-stream"

  defp upload_output(bucket, original_key, player_output, upload_result) do
    output = %{
      "bucket" => bucket,
      "original_key" => original_key,
      "original_uri" => "s3://#{bucket}/#{original_key}",
      "player_key" => player_output["player_key"],
      "player_uri" => player_output["player_uri"],
      "bytes" => upload_result.bytes,
      "content_type" => upload_result.content_type
    }

    case Map.get(upload_result, :mode) do
      mode when is_binary(mode) -> Map.put(output, "mode", mode)
      _other -> output
    end
  end

  defp upload_artifacts(output, source_url, space_hash, embed_hash, version) do
    [
      %{
        name: "original",
        uri: output["original_uri"],
        media_type: output["content_type"],
        size_bytes: output["bytes"],
        metadata: %{
          "source_url" => source_url,
          "space_hash" => space_hash,
          "embed_hash" => embed_hash,
          "version" => version
        }
      },
      %{
        name: "player_html",
        uri: output["player_uri"],
        media_type: "text/html",
        metadata: %{
          "space_hash" => space_hash,
          "embed_hash" => embed_hash,
          "version" => version
        }
      }
    ]
  end

  defp find_content_type_value(values) do
    Enum.find_value(values, fn
      value when is_binary(value) ->
        value

      value when is_list(value) ->
        list_content_type_value(value)

      _ ->
        nil
    end)
  end

  defp list_content_type_value(value) do
    if Enum.all?(value, fn item -> is_integer(item) end) do
      List.to_string(value)
    else
      nil
    end
  end

  defp build_original_key(embed_hash, version) do
    with {:ok, embed_hash} <- StepSupport.require_binary(embed_hash, :embed_hash) do
      key =
        if StepSupport.normalize_version(version) > 0 do
          "#{embed_hash}/v#{version}/original"
        else
          "#{embed_hash}/original"
        end

      {:ok, key}
    end
  end
end
