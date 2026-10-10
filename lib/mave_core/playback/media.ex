defmodule MaveCore.Playback.Media do
  @moduledoc false

  alias MaveCore.Embeds.{ManifestPublisher, SettingsSerializer}
  alias MaveCore.Media.Storage

  @max_playlist_bytes 2_000_000
  @thumbnail_cache_seconds 300
  @thumbnail_url_ttl 86_400

  # Call only for an authorized dashboard listing. The signature covers one image.
  def dashboard_thumbnail_url(space, embed, cache_buster) do
    now = System.system_time(:second)
    signed_at = now - rem(now, @thumbnail_cache_seconds)
    bucket = Storage.bucket_for_space(space.hash, space.region)
    query = [{"response-cache-control", "private, max-age=#{@thumbnail_cache_seconds}"}]
    query = if cache_buster, do: query ++ [{"e", cache_buster}], else: query

    case storage().presigned_get_url(bucket, embed.hash <> "/thumbnail.jpg", space.region,
           datetime: DateTime.from_unix!(signed_at),
           expires: @thumbnail_url_ttl,
           query_params: query
         ) do
      {:ok, url} -> url
      {:error, _reason} -> nil
    end
  end

  def response(embed, "manifest.json", base, token, _expires_at) do
    with {:ok, manifest} <- ManifestPublisher.current(embed) do
      {:ok, "application/json", Jason.encode!(rewrite_manifest(manifest, embed, base, token))}
    end
  end

  def response(embed, path, base, token, expires_at) do
    with :ok <- valid_path(path) do
      cond do
        String.ends_with?(path, ".m3u8") -> playlist(embed, path, base, token, expires_at)
        Path.basename(path) == "storyboard.vtt" -> storyboard(embed, path, expires_at)
        true -> signed_url(embed, path, expires_at)
      end
    end
  end

  def valid_path(path) when is_binary(path) and byte_size(path) <= 2048 do
    segments = String.split(path, "/")

    if Enum.all?(segments, &Regex.match?(~r/\A[A-Za-z0-9_.-]+\z/, &1)) and
         Enum.all?(segments, &(&1 not in [".", "..", ""])) do
      :ok
    else
      {:error, :invalid_path}
    end
  end

  def valid_path(_path), do: {:error, :invalid_path}

  def media_url(base, path, token),
    do: base <> "/" <> path <> "?" <> URI.encode_query(%{"token" => token})

  defp signed_url(embed, path, expires_at) do
    ttl = expires_at - System.system_time(:second)
    bucket = Storage.bucket_for_space(embed.space.hash, embed.space.region)

    if ttl > 0 do
      case storage().presigned_get_url(bucket, embed.hash <> "/" <> path, embed.space.region,
             expires: ttl
           ) do
        {:ok, url} -> {:redirect, url}
        {:error, _reason} -> {:error, :storage_unavailable}
      end
    else
      {:error, :expired}
    end
  end

  defp playlist(embed, path, base, token, expires_at) do
    bucket = Storage.bucket_for_space(embed.space.hash, embed.space.region)
    key = embed.hash <> "/" <> path

    with {:ok, %{size_bytes: size}} when size <= @max_playlist_bytes <-
           storage().object_info(bucket, key, embed.space.region),
         {:ok, body} when is_binary(body) and byte_size(body) <= @max_playlist_bytes <-
           storage().get(bucket, key, embed.space.region),
         {:ok, lines} <-
           rewrite_lines(String.split(body, "\n"), embed, path, base, token, expires_at) do
      {:ok, "application/vnd.apple.mpegurl", Enum.join(lines, "\n")}
    else
      _ -> {:error, :playlist_unavailable}
    end
  end

  defp storyboard(embed, path, expires_at) do
    bucket = Storage.bucket_for_space(embed.space.hash, embed.space.region)
    key = embed.hash <> "/" <> path

    with {:ok, %{size_bytes: size}} when size <= @max_playlist_bytes <-
           storage().object_info(bucket, key, embed.space.region),
         {:ok, body} when is_binary(body) and byte_size(body) <= @max_playlist_bytes <-
           storage().get(bucket, key, embed.space.region) do
      rewrite_storyboard(body, embed, path, expires_at)
    else
      _ -> {:error, :storyboard_unavailable}
    end
  end

  defp rewrite_storyboard(body, embed, path, expires_at) do
    body
    |> String.split("\n")
    |> Enum.reduce_while({:ok, []}, fn line, {:ok, lines} ->
      case storyboard_line(line, embed, path, expires_at) do
        {:ok, rewritten} -> {:cont, {:ok, [rewritten | lines]}}
        error -> {:halt, error}
      end
    end)
    |> case do
      {:ok, lines} -> {:ok, "text/vtt", lines |> Enum.reverse() |> Enum.join("\n")}
      error -> error
    end
  end

  defp storyboard_line(line, embed, path, expires_at) do
    case String.split(String.trim(line), "#xywh=", parts: 2) do
      [raw, coordinates] ->
        with true <- Regex.match?(~r/\A\d+,\d+,\d+,\d+\z/, coordinates),
             {:ok, target} <- resolve_path(raw, embed, Path.dirname(path)),
             {:redirect, url} <- signed_url(embed, target, expires_at) do
          {:ok, url <> "#xywh=" <> coordinates}
        else
          _ -> {:error, :invalid_storyboard}
        end

      _ ->
        {:ok, line}
    end
  end

  defp rewrite_lines(lines, embed, path, base, token, expires_at) do
    Enum.reduce_while(lines, {:ok, []}, fn line, {:ok, acc} ->
      case rewrite_line(line, embed, path, base, token, expires_at) do
        {:ok, rewritten} -> {:cont, {:ok, [rewritten | acc]}}
        error -> {:halt, error}
      end
    end)
    |> case do
      {:ok, lines} -> {:ok, Enum.reverse(lines)}
      error -> error
    end
  end

  defp rewrite_line("#" <> _ = line, embed, path, base, token, expires_at) do
    matches = Regex.scan(~r/URI="([^"]+)"/, line, capture: :all_but_first)

    Enum.reduce_while(matches, {:ok, line}, fn [raw], {:ok, text} ->
      case playlist_url(raw, embed, path, base, token, expires_at) do
        {:ok, url} -> {:cont, {:ok, String.replace(text, "URI=\"#{raw}\"", "URI=\"#{url}\"")}}
        error -> {:halt, error}
      end
    end)
  end

  defp rewrite_line(line, embed, path, base, token, expires_at) do
    if String.trim(line) == "",
      do: {:ok, line},
      else: playlist_url(String.trim(line), embed, path, base, token, expires_at)
  end

  defp playlist_url(raw, embed, path, base, token, expires_at) do
    with {:ok, target} <- resolve_path(raw, embed, Path.dirname(path)),
         :ok <- valid_path(target) do
      if String.ends_with?(target, ".m3u8") do
        {:ok, media_url(base, target, token)}
      else
        playlist_signed_url(embed, target, expires_at)
      end
    end
  end

  defp playlist_signed_url(embed, target, expires_at) do
    case signed_url(embed, target, expires_at) do
      {:redirect, url} -> {:ok, url}
      error -> error
    end
  end

  def resolve_path(raw, %{hash: hash, space: space}, directory) do
    bucket = Storage.bucket_for_space(space.hash, space.region)
    prefix = SettingsSerializer.storage_object_url(bucket, hash <> "/") |> URI.parse()
    uri = URI.parse(raw)

    # Path-style S3 origins include the bucket before the embed hash.
    if is_binary(uri.path) and String.starts_with?(uri.path, prefix.path) do
      resolve_path(String.replace_prefix(uri.path, prefix.path, ""), hash, ".")
    else
      resolve_path(raw, hash, directory)
    end
  end

  def resolve_path(raw, embed_hash, directory) when is_binary(embed_hash) do
    uri = URI.parse(raw)
    path = uri.path || ""
    prefix = "/#{embed_hash}/"

    target =
      cond do
        String.starts_with?(path, prefix) -> String.replace_prefix(path, prefix, "")
        absolute_path?(uri) -> nil
        directory in [".", ""] -> path
        true -> Path.join(directory, path)
      end

    if is_binary(target) and valid_path(target) == :ok,
      do: {:ok, target},
      else: {:error, :invalid_path}
  end

  defp absolute_path?(uri),
    do: uri.scheme != nil or uri.host != nil or String.starts_with?(uri.path || "", "/")

  defp rewrite_manifest(value, embed, base, token) when is_map(value) do
    Map.new(value, fn {key, child} -> {key, rewrite_manifest(child, embed, base, token)} end)
  end

  defp rewrite_manifest(value, embed, base, token) when is_list(value),
    do: Enum.map(value, &rewrite_manifest(&1, embed, base, token))

  defp rewrite_manifest(value, embed, base, token) when is_binary(value) do
    if String.starts_with?(value, ["https://", "http://", "/#{embed.hash}/"]) do
      case resolve_path(value, embed, ".") do
        {:ok, path} -> media_url(base, path, token)
        _ -> nil
      end
    else
      value
    end
  end

  defp rewrite_manifest(value, _embed, _base, _token), do: value
  defp storage, do: Application.get_env(:mave_core, :playback_storage_adapter, Storage)
end
