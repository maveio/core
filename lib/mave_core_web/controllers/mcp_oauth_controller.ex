defmodule MaveCoreWeb.McpOauthController do
  use MaveCoreWeb, :controller

  alias MaveCore.MCP.{Config, OAuth}
  alias MaveCoreWeb.Plugs.EventIngestRateLimit

  plug EventIngestRateLimit,
       [bucket: :mcp_registration, interval_ms: 60_000, max_requests: 10] when action == :register

  plug EventIngestRateLimit,
       [bucket: :mcp_oauth_token, interval_ms: 60_000, max_requests: 120]
       when action in [:token, :revoke]

  plug :no_store

  def resource(conn, _) do
    json(conn, %{
      resource: Config.resource_url(),
      authorization_servers: [Config.issuer()],
      scopes_supported: Config.scopes(),
      bearer_methods_supported: ["header"],
      resource_name: "Mave"
    })
  end

  def metadata(conn, _) do
    issuer = Config.issuer()

    json(conn, %{
      issuer: issuer,
      authorization_endpoint: Config.authorization_url(),
      token_endpoint: issuer <> "/oauth/mcp/token",
      registration_endpoint: issuer <> "/oauth/mcp/register",
      revocation_endpoint: issuer <> "/oauth/mcp/revoke",
      scopes_supported: Config.scopes(),
      response_types_supported: ["code"],
      grant_types_supported: ["authorization_code", "refresh_token"],
      code_challenge_methods_supported: ["S256"],
      token_endpoint_auth_methods_supported: ["none"],
      revocation_endpoint_auth_methods_supported: ["none"]
    })
  end

  def register(conn, params) do
    case OAuth.register(params) do
      {:ok, client} -> conn |> put_status(:created) |> json(OAuth.client_metadata(client))
      {:error, _} -> error(conn, :invalid_client_metadata)
    end
  end

  def token(conn, params) do
    case OAuth.exchange(params) do
      {:ok, response} -> json(conn, response)
      {:error, reason} -> error(conn, reason)
    end
  end

  def revoke(conn, params) do
    :ok = OAuth.revoke_token(params)
    send_resp(conn, :ok, "")
  end

  defp error(conn, reason), do: conn |> put_status(:bad_request) |> json(%{error: reason})

  defp no_store(conn, _),
    do:
      conn
      |> put_resp_header("cache-control", "no-store")
      |> put_resp_header("pragma", "no-cache")
end
