defmodule MaveCoreWeb.Api.CliAuthorizationsController do
  use MaveCoreWeb, :controller

  alias MaveCore.CliAuthorizations
  alias MaveCoreWeb.Plugs.EventIngestRateLimit

  plug EventIngestRateLimit,
       [bucket: :cli_authorization_create, interval_ms: 60_000, max_requests: 20]
       when action == :create

  plug EventIngestRateLimit,
       [bucket: :cli_authorization_exchange, interval_ms: 60_000, max_requests: 180]
       when action == :exchange

  def create(conn, params) do
    case CliAuthorizations.create_authorization(client_metadata: params) do
      {:ok, %{authorization: authorization, device_code: device_code}} ->
        verification_uri = verification_uri(conn)

        conn
        |> put_status(:created)
        |> put_resp_header("cache-control", "no-store")
        |> json(%{
          device_code: device_code,
          user_code: authorization.user_code,
          verification_uri: verification_uri,
          verification_uri_complete: verification_uri <> "/" <> authorization.user_code,
          expires_in: CliAuthorizations.expires_in_seconds(),
          interval: CliAuthorizations.poll_interval_seconds()
        })

      {:error, _reason} ->
        conn
        |> put_status(:service_unavailable)
        |> json(%{error: "authorization_unavailable"})
    end
  end

  def exchange(conn, %{"device_code" => device_code}) when is_binary(device_code) do
    case CliAuthorizations.exchange(device_code) do
      {:ok, token} ->
        conn
        |> put_resp_header("cache-control", "no-store")
        |> json(token)

      {:error, :authorization_pending} ->
        error(conn, :bad_request, "authorization_pending")

      {:error, :access_denied} ->
        error(conn, :forbidden, "access_denied")

      {:error, :expired_token} ->
        error(conn, :bad_request, "expired_token")

      {:error, :invalid_grant} ->
        error(conn, :bad_request, "invalid_grant")

      {:error, _reason} ->
        error(conn, :service_unavailable, "authorization_unavailable")
    end
  end

  def exchange(conn, _params), do: error(conn, :bad_request, "invalid_request")

  defp error(conn, status, reason) do
    conn
    |> put_status(status)
    |> put_resp_header("cache-control", "no-store")
    |> json(%{error: reason})
  end

  defp verification_uri(conn) do
    base_url =
      case Application.get_env(:mave_core, :domain) do
        value when is_binary(value) and value != "" -> String.trim_trailing(value, "/")
        _ -> request_base_url(conn)
      end

    base_url <> "/cli/auth"
  end

  defp request_base_url(conn) do
    default_port? =
      (conn.scheme == :http and conn.port == 80) or
        (conn.scheme == :https and conn.port == 443)

    port = if default_port?, do: "", else: ":#{conn.port}"
    "#{conn.scheme}://#{conn.host}#{port}"
  end
end
