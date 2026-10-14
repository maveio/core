defmodule MaveCoreWeb.McpController do
  @moduledoc "Stateless JSON-response Streamable HTTP transport for MCP 2025 clients."
  use MaveCoreWeb, :controller

  alias MaveCore.MCP.{Config, OAuth, Tools}
  alias MaveCoreWeb.Plugs.EventIngestRateLimit

  @versions ["2025-11-25", "2025-06-18", "2025-03-26"]
  plug EventIngestRateLimit, bucket: :mcp, interval_ms: 60_000, max_requests: 300
  plug :authenticate

  def handle(%{method: "POST"} = conn, _params) do
    with :ok <- accept(conn),
         :ok <- version(conn) do
      dispatch(conn, conn.body_params)
    else
      {:error, status, message} -> rpc_error(conn, nil, -32_000, message, status)
    end
  end

  def handle(conn, _params) do
    conn |> put_resp_header("allow", "POST, OPTIONS") |> send_resp(:method_not_allowed, "")
  end

  defp dispatch(conn, %{"jsonrpc" => "2.0", "method" => method} = request)
       when is_binary(method) do
    params = Map.get(request, "params", %{})

    cond do
      not is_map(params) ->
        rpc_error(conn, request["id"], -32_602, "Invalid params")

      not Map.has_key?(request, "id") ->
        send_resp(conn, :accepted, "")

      not (is_binary(request["id"]) or is_integer(request["id"])) ->
        rpc_error(conn, nil, -32_600, "Invalid Request")

      true ->
        request(conn, request["id"], method, params)
    end
  end

  defp dispatch(conn, _), do: rpc_error(conn, nil, -32_600, "Invalid Request")

  defp request(conn, id, "initialize", %{"protocolVersion" => version}) when is_binary(version) do
    negotiated = if version in @versions, do: version, else: hd(@versions)

    result(conn, id, %{
      protocolVersion: negotiated,
      capabilities: %{tools: %{listChanged: false}},
      serverInfo: %{name: "mave", version: Application.spec(:mave_core, :vsn) |> to_string()},
      instructions:
        "Manage videos and collections only in the connected Mave space. Confirm deletions with the user. Video imports process asynchronously."
    })
  end

  defp request(conn, id, "initialize", _),
    do: rpc_error(conn, id, -32_602, "Invalid initialization params")

  defp request(conn, id, "ping", _), do: result(conn, id, %{})

  defp request(conn, id, "tools/list", params) when map_size(params) == 0,
    do: result(conn, id, %{tools: Tools.list(conn.assigns.mcp_grant)})

  defp request(conn, id, "tools/list", _), do: rpc_error(conn, id, -32_602, "Invalid cursor")

  defp request(conn, id, "tools/call", %{"name" => name} = params) when is_binary(name) do
    case Tools.call(conn.assigns.mcp_grant, name, Map.get(params, "arguments", %{})) do
      {:ok, response} ->
        result(conn, id, response)

      {:error, :invalid_params} ->
        rpc_error(conn, id, -32_602, "Unknown or unauthorized tool, or invalid arguments")
    end
  end

  defp request(conn, id, "tools/call", _), do: rpc_error(conn, id, -32_602, "Invalid tool call")
  defp request(conn, id, _, _), do: rpc_error(conn, id, -32_601, "Method not found")
  defp result(conn, id, result), do: json(conn, %{jsonrpc: "2.0", id: id, result: result})

  defp rpc_error(conn, id, code, message, status \\ :ok),
    do:
      conn
      |> put_status(status)
      |> json(%{jsonrpc: "2.0", id: id, error: %{code: code, message: message}})

  defp authenticate(conn, _) do
    conn =
      conn
      |> put_resp_header("cache-control", "no-store")
      |> put_resp_header("pragma", "no-cache")

    with ["Bearer " <> token] <- get_req_header(conn, "authorization"),
         {:ok, grant} <- OAuth.authenticate(token) do
      assign(conn, :mcp_grant, grant)
    else
      _ ->
        conn
        |> put_resp_header(
          "www-authenticate",
          ~s(Bearer resource_metadata="#{Config.issuer()}/.well-known/oauth-protected-resource/mcp", scope="mave:read")
        )
        |> put_status(:unauthorized)
        |> json(%{error: "invalid_token"})
        |> halt()
    end
  end

  defp accept(conn) do
    accepts = get_req_header(conn, "accept") |> Enum.join(",")
    content_type = get_req_header(conn, "content-type") |> List.first("")

    cond do
      not String.starts_with?(content_type, "application/json") ->
        {:error, :unsupported_media_type, "Content-Type must be application/json"}

      not (String.contains?(accepts, "application/json") and
               String.contains?(accepts, "text/event-stream")) ->
        {:error, :not_acceptable, "Accept must include application/json and text/event-stream"}

      true ->
        :ok
    end
  end

  defp version(conn) do
    case get_req_header(conn, "mcp-protocol-version") do
      [] -> :ok
      [version] when version in @versions -> :ok
      _ -> {:error, :bad_request, "Unsupported MCP protocol version"}
    end
  end
end
