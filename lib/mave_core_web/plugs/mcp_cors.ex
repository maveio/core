defmodule MaveCoreWeb.Plugs.McpCORS do
  @moduledoc false
  import Plug.Conn
  alias MaveCore.MCP.Config

  def init(opts), do: opts

  def call(conn, _opts) do
    case get_req_header(conn, "origin") do
      [] ->
        preflight(conn)

      [origin] ->
        if origin in Config.allowed_origins() do
          conn
          |> put_resp_header("access-control-allow-origin", origin)
          |> put_resp_header("vary", "origin")
          |> preflight()
        else
          conn |> send_resp(:forbidden, "Origin not allowed") |> halt()
        end

      _ ->
        conn |> send_resp(:forbidden, "Origin not allowed") |> halt()
    end
  end

  defp preflight(conn) do
    conn =
      conn
      |> put_resp_header("access-control-allow-methods", "GET, POST, DELETE, OPTIONS")
      |> put_resp_header(
        "access-control-allow-headers",
        "authorization, content-type, accept, mcp-protocol-version, mcp-session-id, last-event-id"
      )
      |> put_resp_header(
        "access-control-expose-headers",
        "www-authenticate, mcp-protocol-version"
      )

    if conn.method == "OPTIONS", do: conn |> send_resp(:no_content, "") |> halt(), else: conn
  end
end
