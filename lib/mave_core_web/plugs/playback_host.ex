defmodule MaveCoreWeb.Plugs.PlaybackHost do
  @moduledoc "Routes a configured media hostname without exposing dashboard or management routes."
  @behaviour Plug

  import Plug.Conn

  alias MaveCore.Playback.URLs
  alias MaveCoreWeb.Api.PlaybackController
  alias MaveCoreWeb.Plugs.CORS

  def init(opts), do: opts

  def call(conn, _opts) do
    if URLs.playback_host?(conn.host), do: serve(conn), else: conn
  end

  defp serve(conn) do
    conn = CORS.call(conn, [])

    if conn.halted do
      conn
    else
      dispatch(conn) |> halt()
    end
  end

  defp dispatch(%{method: method, path_info: [hash | path]} = conn)
       when method in ["GET", "HEAD"] and path != [] do
    with {:ok, space_hash} <- URLs.space_hash(conn.host),
         true <- Regex.match?(~r/\A[A-Za-z0-9]{10}\z/, hash) do
      conn = fetch_query_params(conn)
      # URL identity comes only from the configured host and path, never query parameters.
      params = Map.merge(conn.query_params, %{"id" => space_hash <> hash, "path" => path})
      PlaybackController.show(conn, params)
    else
      _ -> send_resp(conn, 404, "Not found")
    end
  end

  defp dispatch(conn), do: send_resp(conn, 404, "Not found")
end
