defmodule MaveCoreWeb.Plugs.ApiKeyAuth do
  @moduledoc false

  import Plug.Conn
  use MaveCoreWeb, :controller

  alias MaveCore.Spaces

  def init(opts), do: opts

  def call(conn, _opts) do
    with {:ok, key_id, secret} <- fetch_credentials(conn),
         {:ok, key, space} <- Spaces.authenticate_api_key(key_id, secret) do
      conn
      |> assign(:current_api_key, key)
      |> assign(:current_space, space)
    else
      _ -> unauthorized(conn)
    end
  end

  defp fetch_credentials(conn) do
    case get_req_header(conn, "authorization") do
      ["Bearer " <> token] -> decode_bearer(token)
      _ -> parse_basic(conn)
    end
  end

  defp decode_bearer(token) when is_binary(token) do
    with {:ok, decoded} <- Base.decode64(token),
         [key_id, secret | _rest] <- String.split(decoded, ":", parts: 2) do
      {:ok, key_id, secret}
    else
      _ -> :error
    end
  end

  defp parse_basic(conn) do
    case Plug.BasicAuth.parse_basic_auth(conn) do
      {key_id, secret} -> {:ok, key_id, secret}
      _ -> :error
    end
  end

  defp unauthorized(conn) do
    conn
    |> put_status(:unauthorized)
    |> json(%{error: "You're not authorized to make this request"})
    |> halt()
  end
end
