defmodule MaveCoreWeb.Plugs.CORS do
  @moduledoc false

  @behaviour Plug

  import Plug.Conn

  @allowed_headers "authorization, content-type, x-api-key"
  @allowed_methods "GET, POST, PUT, DELETE, OPTIONS"

  def init(opts), do: opts

  def call(conn, opts) do
    # Public components authenticate explicitly. Only anonymous metrics enables
    # credentials mode, because browsers require it for JSON sendBeacon requests.
    conn =
      conn
      |> put_origin(opts)
      |> put_resp_header("access-control-allow-methods", @allowed_methods)
      |> put_resp_header("access-control-allow-headers", @allowed_headers)
      |> put_resp_header("access-control-max-age", "86400")

    if conn.method == "OPTIONS" do
      conn
      |> send_resp(:no_content, "")
      |> halt()
    else
      conn
    end
  end

  defp put_origin(conn, opts) do
    origin = conn |> get_req_header("origin") |> List.first()

    if opts[:allow_beacon] && http_origin?(origin) do
      conn
      |> put_resp_header("access-control-allow-origin", origin)
      |> put_resp_header("access-control-allow-credentials", "true")
      |> put_resp_header("vary", "origin")
    else
      put_resp_header(conn, "access-control-allow-origin", "*")
    end
  end

  defp http_origin?(origin) when is_binary(origin) do
    case URI.parse(origin) do
      %URI{scheme: scheme, host: host} when scheme in ["http", "https"] and is_binary(host) ->
        true

      _ ->
        false
    end
  end

  defp http_origin?(_origin), do: false
end
