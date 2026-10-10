defmodule MaveCoreWeb.BrowserSecurity do
  @moduledoc false
  alias MaveCore.Playback.URLs

  def init(opts), do: opts

  def call(conn, _opts) do
    Plug.Conn.put_resp_header(conn, "content-security-policy", content_security_policy())
  end

  def content_security_policy do
    component_sources =
      component_script_origins()
      |> Enum.join(" ")

    script_src =
      ["'self'", "'unsafe-eval'", component_sources]
      |> Enum.reject(&(&1 in [nil, ""]))
      |> Enum.join(" ")

    external_sources =
      configured_external_origins()
      |> Enum.join(" ")

    "default-src 'self'; " <>
      "base-uri 'self'; " <>
      "frame-ancestors 'self'; " <>
      "form-action 'self'; " <>
      "object-src 'none'; " <>
      "script-src #{script_src}; " <>
      "style-src 'self' 'unsafe-inline'; " <>
      "img-src 'self' https: data: blob: #{external_sources}; " <>
      "font-src 'self' data:; " <>
      "connect-src 'self' https: ws: wss: #{external_sources}; " <>
      "media-src 'self' https: blob: #{external_sources}"
  end

  defp component_script_origins do
    [
      "https://cdn.video-dns.com/npm/@maveio/components",
      Application.get_env(:mave_core, :components_base_url),
      Application.get_env(:mave_core, :components_src)
    ]
    |> Enum.flat_map(&extract_origin/1)
    |> Enum.uniq()
  end

  defp configured_external_origins do
    upload = Application.get_env(:mave_core, :upload, [])

    [
      Application.get_env(:mave_core, :domain),
      Application.get_env(:mave_core, :public_cdn_base_url),
      Application.get_env(:mave_core, :playback_public_storage_endpoint),
      playback_origin(),
      Application.get_env(:mave_core, :image_base_url),
      Keyword.get(upload, :endpoint),
      Keyword.get(upload, :public_base_url)
    ]
    |> Enum.flat_map(&extract_origin/1)
    |> Enum.uniq()
  end

  defp extract_origin(value) when is_binary(value) and value != "" do
    value
    |> URI.parse()
    |> case do
      %URI{scheme: scheme, host: host} = uri when is_binary(scheme) and is_binary(host) ->
        [
          URI.to_string(%URI{scheme: scheme, host: host, port: uri.port})
          |> String.trim_trailing("/")
        ]

      _ ->
        []
    end
  end

  defp extract_origin(_), do: []

  defp playback_origin do
    case URLs.origin() do
      %URI{} = uri -> URI.to_string(%{uri | host: "*." <> uri.host})
      nil -> nil
    end
  end
end
