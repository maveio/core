defmodule MaveCore.Playback.URLs do
  @moduledoc false

  def origin do
    case Application.get_env(:mave_core, :playback_origin) do
      value when is_binary(value) and value != "" -> URI.parse(value)
      _ -> nil
    end
  end

  def endpoint(api_endpoint) do
    case origin() do
      %URI{} = uri ->
        URI.to_string(%{
          uri
          | host: "space-${this.spaceId}." <> uri.host,
            path: "/${this.embedId}"
        })

      nil ->
        String.trim_trailing(api_endpoint, "/") <>
          "/playback/media/${this.spaceId}${this.embedId}"
    end
  end

  def media_url(endpoint, space_hash, embed_hash, path) do
    endpoint
    |> String.replace("${this.spaceId}", space_hash)
    |> String.replace("${this.embedId}", embed_hash)
    |> Kernel.<>("/" <> path)
  end

  def space_hash(host) do
    with %URI{host: suffix} <- origin(),
         host = String.downcase(host),
         true <- String.ends_with?(host, "." <> suffix),
         "space-" <> hash <- String.replace_suffix(host, "." <> suffix, ""),
         true <- Regex.match?(~r/\A[a-z0-9]{5}\z/, hash) do
      {:ok, hash}
    else
      _ -> :error
    end
  end

  def playback_host?(host) do
    case origin() do
      %URI{host: suffix} ->
        host = String.downcase(host)
        host == suffix or String.ends_with?(host, "." <> suffix)

      nil ->
        false
    end
  end
end
