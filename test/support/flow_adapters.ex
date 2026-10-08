defmodule MaveCore.TestSupport.FlowStorageAdapterStub do
  @moduledoc false

  @table :mave_core_flow_storage_adapter_stub

  def bucket_for_space(space_hash, _region \\ nil), do: "space-#{space_hash}"

  def ensure_bucket(_bucket, _region), do: :ok

  def ensure_ffmpeg_bucket_access_policy(_bucket, _region), do: :ok

  def put(bucket, path, body, content_type, region) do
    body = normalize_body(body)
    :ets.insert(table(), {{bucket, path, region}, body})
    :ets.insert(table(), {{:content_type, bucket, path, region}, content_type})
    :ets.insert(table(), {{:public, bucket, path, region}, false})
    {:ok, body}
  end

  def put_public(bucket, path, body, content_type, region) do
    case :ets.lookup(table(), {:put_public_failure, bucket, path, region}) do
      [{{:put_public_failure, ^bucket, ^path, ^region}, {:after_write, reason}}] ->
        body = normalize_body(body)
        store_public_object(bucket, path, body, content_type, region)
        {:error, reason}

      [{{:put_public_failure, ^bucket, ^path, ^region}, reason}] ->
        {:error, reason}

      [] ->
        body = normalize_body(body)
        store_public_object(bucket, path, body, content_type, region)
        {:ok, body}
    end
  end

  def fail_public_put!(bucket, path, region, reason \\ :synthetic_put_failure) do
    :ets.insert(table(), {{:put_public_failure, bucket, path, region}, reason})
    :ok
  end

  def put_file_public(bucket, path, source_path, content_type, region) do
    with {:ok, body} <- File.read(source_path) do
      put_public(bucket, path, body, content_type, region)
    end
  end

  def start_presigned_multipart_upload(bucket, path, region, content_type, opts) do
    upload_id = "test-#{System.unique_integer([:positive])}"
    :ets.insert(table(), {{:multipart_upload_opts, bucket, path, region}, opts})

    {:ok,
     %{
       bucket: bucket,
       path: path,
       storage_profile: region,
       upload_id: upload_id,
       payload: %{
         "test_bucket" => bucket,
         "test_path" => path,
         "test_region" => region,
         "test_content_type" => content_type
       }
     }}
  end

  def multipart_upload_opts(bucket, path, region) do
    case :ets.lookup(table(), {:multipart_upload_opts, bucket, path, region}) do
      [{{:multipart_upload_opts, ^bucket, ^path, ^region}, opts}] -> opts
      [] -> nil
    end
  end

  def abort_presigned_multipart_upload(_session), do: :ok

  def ffmpeg_input_url(bucket, path, _region) do
    {:ok, "https://storage.example/#{bucket}/#{path}"}
  end

  def presigned_get_url(bucket, path, _region, _opts) do
    {:ok, "https://storage.example/#{bucket}/#{path}?signature=test"}
  end

  defp store_public_object(bucket, path, body, content_type, region) do
    :ets.insert(table(), {{bucket, path, region}, body})
    :ets.insert(table(), {{:content_type, bucket, path, region}, content_type})
    :ets.insert(table(), {{:public, bucket, path, region}, true})
  end

  def copy_public(destination_bucket, destination_path, source_bucket, source_path, region) do
    case get(source_bucket, source_path, region) do
      {:ok, body} ->
        content_type = content_type(source_bucket, source_path, region)
        put_public(destination_bucket, destination_path, body, content_type, region)
        :ok

      {:error, reason} ->
        {:error, reason}
    end
  end

  def copy_public_between_profiles(
        destination_bucket,
        destination_path,
        destination_region,
        source_bucket,
        source_path,
        source_region
      ) do
    :ets.insert(
      table(),
      {{:copy_between_profiles, destination_bucket, destination_path, destination_region},
       {source_bucket, source_path, source_region}}
    )

    case get(source_bucket, source_path, source_region) do
      {:ok, body} ->
        content_type = content_type(source_bucket, source_path, source_region)
        put_public(destination_bucket, destination_path, body, content_type, destination_region)
        :ok

      {:error, reason} ->
        {:error, reason}
    end
  end

  def copy_prefix_public(
        destination_bucket,
        destination_prefix,
        destination_region,
        source_bucket,
        source_prefix,
        source_region
      ) do
    {:ok, keys} = list_prefix_keys(source_bucket, source_prefix, source_region)

    Enum.reduce_while(keys, :ok, fn source_key, :ok ->
      destination_key =
        destination_prefix <> String.replace_prefix(source_key, source_prefix, "")

      case get(source_bucket, source_key, source_region) do
        {:ok, body} ->
          content_type = content_type(source_bucket, source_key, source_region)

          put_public(
            destination_bucket,
            destination_key,
            body,
            content_type,
            destination_region
          )

          {:cont, :ok}

        {:error, reason} ->
          {:halt, {:error, reason}}
      end
    end)
  end

  def delete_prefix(bucket, prefix, region) do
    with {:ok, keys} <- list_prefix_keys(bucket, prefix, region) do
      Enum.each(keys, &delete_object_data(bucket, &1, region))
      :ok
    end
  end

  def delete_object(bucket, path, region) do
    delete_object_data(bucket, path, region)
  end

  def list_prefix_keys(bucket, prefix, region) do
    keys =
      table()
      |> :ets.tab2list()
      |> Enum.flat_map(fn
        {{^bucket, path, ^region}, body} when is_binary(path) and is_binary(body) ->
          [path]

        _ ->
          []
      end)
      |> Enum.filter(&String.starts_with?(&1, prefix))
      |> Enum.sort()

    {:ok, keys}
  end

  def object_info(bucket, path, region) do
    case get(bucket, path, region) do
      {:ok, body} ->
        {:ok,
         %{
           size_bytes: byte_size(body),
           content_type: content_type(bucket, path, region)
         }}

      {:error, reason} ->
        {:error, reason}
    end
  end

  def update_embed_visibility(
        %MaveCore.Spaces.Space{hash: space_hash},
        embed_hash,
        visibility,
        region
      ) do
    update_embed_visibility(space_hash, embed_hash, visibility, region)
  end

  def update_embed_visibility(space_hash, embed_hash, visibility, region) do
    :ets.insert(table(), {{:visibility, space_hash, embed_hash, region}, visibility})
    :ok
  end

  def set_object_visibility(bucket, path, visibility, region) do
    :ets.insert(table(), {{:public, bucket, path, region}, visibility == "public"})
    :ok
  end

  def get(bucket, path, region) do
    case :ets.lookup(table(), {bucket, path, region}) do
      [{{^bucket, ^path, ^region}, body}] ->
        {:ok, body}

      [] ->
        case :ets.lookup(table(), {bucket, path, nil}) do
          [{{^bucket, ^path, nil}, body}] -> {:ok, body}
          [] -> {:error, :not_found}
        end
    end
  end

  def get_prefix(bucket, path, region, max_bytes) when is_integer(max_bytes) and max_bytes > 0 do
    case get(bucket, path, region) do
      {:ok, body} when is_binary(body) ->
        {:ok, binary_part(body, 0, min(byte_size(body), max_bytes))}

      other ->
        other
    end
  end

  def download_to_file(bucket, path, destination_path, region) do
    case get(bucket, path, region) do
      {:ok, body} when is_binary(body) -> File.write(destination_path, body)
      other -> other
    end
  end

  def reset! do
    :ets.delete_all_objects(table())
    :ok
  end

  def visibility(space_hash, embed_hash, region) do
    case :ets.lookup(table(), {:visibility, space_hash, embed_hash, region}) do
      [{{:visibility, ^space_hash, ^embed_hash, ^region}, visibility}] -> visibility
      [] -> nil
    end
  end

  def public?(bucket, path, region) do
    case :ets.lookup(table(), {:public, bucket, path, region}) do
      [{{:public, ^bucket, ^path, ^region}, public?}] -> public?
      [] -> nil
    end
  end

  def copy_between_profiles_called?(destination_bucket, destination_path, destination_region) do
    case :ets.lookup(
           table(),
           {:copy_between_profiles, destination_bucket, destination_path, destination_region}
         ) do
      [{_, _source}] -> true
      [] -> false
    end
  end

  defp delete_object_data(bucket, path, region) do
    :ets.delete(table(), {bucket, path, region})
    :ets.delete(table(), {:content_type, bucket, path, region})
    :ets.delete(table(), {:public, bucket, path, region})
    :ok
  end

  defp content_type(bucket, path, region) do
    case :ets.lookup(table(), {:content_type, bucket, path, region}) do
      [{{:content_type, ^bucket, ^path, ^region}, value}] -> value
      [] -> nil
    end
  end

  defp normalize_body(body) when is_binary(body), do: body

  defp normalize_body(body) do
    body
    |> Enum.to_list()
    |> IO.iodata_to_binary()
  end

  defp table do
    case :ets.whereis(@table) do
      :undefined ->
        try do
          :ets.new(@table, [:named_table, :public, :set])
        rescue
          ArgumentError -> :ets.whereis(@table)
        end

      tid ->
        tid
    end
  end
end

defmodule MaveCore.TestSupport.BusyImageGenerationCoordinator do
  @moduledoc false

  def claim(_cache_key, _ttl_ms), do: :busy
  def release(_cache_key, _owner_id), do: :ok
end
