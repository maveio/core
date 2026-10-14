defmodule MaveCoreWeb.Api.PlaybackController do
  use MaveCoreWeb, :controller

  alias MaveCore.Embeds.Embed
  alias MaveCore.Playback
  alias MaveCore.Playback.Media
  alias MaveCore.Playback.Password
  alias MaveCoreWeb.Api.ImageController
  alias MaveCoreWeb.Plugs.PasswordPlaybackRateLimit

  def access(conn, %{"id" => id}) do
    conn = private_response(conn)

    case Playback.get_embed(id) do
      %Embed{} = embed -> json(conn, %{password_protected: Password.protected?(embed)})
      _ -> conn |> put_status(:not_found) |> json(%{error: "not_found"})
    end
  end

  def password_token(conn, %{"id" => id} = params) do
    conn = private_response(conn)
    embed = Playback.get_embed(id)
    conn = PasswordPlaybackRateLimit.call(conn, embed && embed.id)

    if conn.halted do
      conn
    else
      case Password.issue(embed, params["password"]) do
        {:ok, session} -> json(conn, session)
        {:error, :protection_pending} -> password_error(conn, 409, "protection_pending")
        {:error, :playback_unavailable} -> password_error(conn, 503, "playback_unavailable")
        _ -> password_error(conn, 401, "invalid_password")
      end
    end
  end

  defp password_error(conn, status, error),
    do: conn |> put_status(status) |> json(%{error: error})

  def show(conn, %{"id" => id, "path" => path} = params) do
    conn = private_response(conn)
    token = params["token"] || bearer(conn)

    with %Embed{} = embed <- Playback.get_embed(id),
         {:ok, expires_at} <- Playback.authorize(token, embed),
         true <- not Playback.protected?(embed) or Playback.available?(embed.space) do
      base = String.replace_suffix(conn.request_path, "/" <> Enum.join(path, "/"), "")

      base =
        URI.to_string(%URI{
          scheme: Atom.to_string(conn.scheme),
          host: conn.host,
          port: conn.port,
          path: base
        })

      if Enum.join(path, "/") in ["dynamic.jpg", "dynamic.jpeg", "dynamic.webp", "dynamic.avif"] do
        ext = path |> List.first() |> Path.extname()

        ImageController.show(
          %{conn | query_params: Map.put(conn.query_params, "token", token)},
          %{"mave_id" => embed.space.hash <> embed.hash <> ext}
        )
      else
        respond_media(conn, Media.response(embed, Enum.join(path, "/"), base, token, expires_at))
      end
    else
      _ -> send_resp(conn, 401, "Playback authorization required")
    end
  end

  defp respond_media(conn, result) do
    case result do
      {:ok, "application/json", body} ->
        conn |> put_resp_content_type("application/json") |> send_resp(200, body)

      {:ok, "application/vnd.apple.mpegurl", body} ->
        conn |> put_resp_content_type("application/vnd.apple.mpegurl") |> send_resp(200, body)

      {:ok, "text/vtt", body} ->
        conn |> put_resp_content_type("text/vtt") |> send_resp(200, body)

      {:redirect, url} ->
        redirect(conn, external: url)

      {:error, _reason} ->
        send_resp(conn, 404, "Media unavailable")
    end
  end

  defp bearer(conn) do
    case get_req_header(conn, "authorization") do
      ["Bearer " <> token] -> token
      _ -> ""
    end
  end

  defp private_response(conn) do
    conn
    |> put_resp_header("cache-control", "private, no-store")
    |> put_resp_header("referrer-policy", "no-referrer")
    |> put_resp_header("x-content-type-options", "nosniff")
  end
end
