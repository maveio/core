defmodule MaveCoreWeb.Api.PlaybackController do
  use MaveCoreWeb, :controller

  alias MaveCore.Embeds.Embed
  alias MaveCore.Playback
  alias MaveCore.Playback.Media
  alias MaveCoreWeb.Api.ImageController

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
