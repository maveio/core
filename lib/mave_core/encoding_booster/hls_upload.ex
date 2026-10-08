defmodule MaveCore.EncodingBooster.HLSUpload do
  @moduledoc false

  alias MaveCore.Media.Storage
  alias MaveCoreWeb.Endpoint

  @salt "encoding-booster-hls-upload-v1"
  @max_age_seconds 2 * 60 * 60
  @max_files 20_000
  @max_file_size 512 * 1024 * 1024
  @max_total_size 128 * 1024 * 1024 * 1024
  @segment_name ~r/\Asegment_[0-9]{3,6}\.m4s\z/

  @spec sign(String.t(), String.t(), String.t() | nil, keyword()) :: {:ok, String.t()}
  def sign(bucket, prefix, storage_profile, opts \\ [])

  def sign(bucket, prefix, storage_profile, opts)
      when is_binary(bucket) and is_binary(prefix) and prefix != "" and is_list(opts) do
    media_kind = if Keyword.get(opts, :media_kind) == "audio", do: "audio", else: "video"

    {:ok,
     Phoenix.Token.sign(Endpoint, @salt, %{
       "bucket" => bucket,
       "prefix" => prefix,
       "storage_profile" => storage_profile,
       "media_kind" => media_kind,
       "version" => 1
     })}
  rescue
    _error -> {:error, :hls_upload_token_failed}
  end

  def sign(_bucket, _prefix, _storage_profile, _opts),
    do: {:error, :invalid_hls_upload_destination}

  @spec authorize(String.t(), [map()]) :: {:ok, [map()]} | {:error, term()}
  def authorize(token, files) when is_binary(token) and is_list(files) do
    with {:ok, claims} <- verify_token(token),
         :ok <- validate_claims(claims),
         {:ok, validated_files} <- validate_files(files, claims),
         {:ok, uploads} <- presign_files(claims, validated_files) do
      {:ok, uploads}
    else
      {:error, _reason} = error -> error
      _other -> {:error, :invalid_hls_upload_token}
    end
  rescue
    _error -> {:error, :invalid_hls_upload_request}
  end

  def authorize(_token, _files), do: {:error, :invalid_hls_upload_request}

  defp verify_token(token) do
    case Phoenix.Token.verify(Endpoint, @salt, token, max_age: @max_age_seconds) do
      {:ok, claims} -> {:ok, claims}
      {:error, _reason} -> {:error, :invalid_hls_upload_token}
    end
  end

  defp validate_claims(%{
         "bucket" => bucket,
         "prefix" => prefix,
         "version" => 1
       })
       when is_binary(bucket) and bucket != "" and is_binary(prefix) and prefix != "" do
    if String.ends_with?(prefix, "/"),
      do: :ok,
      else: {:error, :invalid_hls_upload_token}
  end

  defp validate_claims(_claims), do: {:error, :invalid_hls_upload_token}

  defp validate_files(files, claims) when length(files) <= @max_files do
    files
    |> Enum.reduce_while(
      {:ok, [], MapSet.new(), 0},
      &validate_file(&1, &2, Map.get(claims, "media_kind", "video"))
    )
    |> case do
      {:ok, validated, _names, _total_size} -> {:ok, Enum.reverse(validated)}
      {:error, _reason} = error -> error
    end
  end

  defp validate_files(_files, _claims), do: {:error, :too_many_hls_upload_files}

  defp validate_file(file, {:ok, validated, names, total_size}, media_kind)
       when is_map(file) do
    name = Map.get(file, "name")
    size = Map.get(file, "size_bytes")
    next_total_size = if is_integer(size), do: total_size + size, else: total_size

    cond do
      not allowed_name?(name) ->
        {:halt, {:error, :invalid_hls_upload_file}}

      MapSet.member?(names, name) ->
        {:halt, {:error, :duplicate_hls_upload_file}}

      not (is_integer(size) and size > 0 and size <= @max_file_size) ->
        {:halt, {:error, :invalid_hls_upload_file_size}}

      next_total_size > @max_total_size ->
        {:halt, {:error, :hls_upload_too_large}}

      true ->
        normalized = %{
          "name" => name,
          "size_bytes" => size,
          "content_type" => content_type(name, media_kind)
        }

        {:cont, {:ok, [normalized | validated], MapSet.put(names, name), next_total_size}}
    end
  end

  defp validate_file(_file, _acc, _media_kind),
    do: {:halt, {:error, :invalid_hls_upload_file}}

  defp allowed_name?("playlist.m3u8"), do: true
  defp allowed_name?("init.mp4"), do: true
  defp allowed_name?(name) when is_binary(name), do: Regex.match?(@segment_name, name)
  defp allowed_name?(_name), do: false

  defp content_type("playlist.m3u8", _media_kind), do: "application/vnd.apple.mpegurl"
  defp content_type(_name, "audio"), do: "audio/mp4"
  defp content_type(_name, _media_kind), do: "video/mp4"

  defp presign_files(claims, files) do
    storage_adapter = Application.get_env(:mave_core, :flow_storage_adapter, Storage)

    files
    |> Task.async_stream(
      &presign_file(storage_adapter, claims, &1),
      max_concurrency: storage_object_max_concurrency(),
      ordered: true,
      timeout: :infinity
    )
    |> Enum.reduce_while({:ok, []}, fn
      {:ok, {:ok, upload}}, {:ok, uploads} -> {:cont, {:ok, [upload | uploads]}}
      {:ok, {:error, reason}}, {:ok, _uploads} -> {:halt, {:error, reason}}
      {:exit, reason}, {:ok, _uploads} -> {:halt, {:error, {:hls_upload_presign_failed, reason}}}
    end)
    |> case do
      {:ok, uploads} -> {:ok, Enum.reverse(uploads)}
      {:error, _reason} = error -> error
    end
  end

  defp presign_file(storage_adapter, claims, file) do
    key = claims["prefix"] <> file["name"]

    with true <- Code.ensure_loaded?(storage_adapter),
         true <- function_exported?(storage_adapter, :presigned_put_url, 6),
         {:ok, destination} <-
           storage_adapter.presigned_put_url(
             claims["bucket"],
             key,
             claims["storage_profile"],
             file["content_type"],
             file["size_bytes"],
             expires: @max_age_seconds
           ) do
      {:ok,
       file
       |> Map.put("key", key)
       |> Map.put("upload", destination)}
    else
      false -> {:error, :hls_direct_upload_unsupported}
      {:error, reason} -> {:error, {:hls_upload_presign_failed, file["name"], reason}}
    end
  end

  defp storage_object_max_concurrency do
    case Application.get_env(:mave_core, :storage_object_max_concurrency, 8) do
      value when is_integer(value) and value > 0 -> value
      _other -> 8
    end
  end
end
