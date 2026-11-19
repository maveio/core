defmodule MaveCoreWeb.Api.LivePlaybackController do
  @moduledoc """
  Public playback of a live stream: its status, the HLS playlist and an
  embeddable player page. Segments are served by the public media origin.
  """
  use MaveCoreWeb, :controller

  alias MaveCore.LiveStreams
  alias MaveCore.LiveStreams.LiveStream
  alias MaveCoreWeb.Api.LivePlayerHTML

  plug :load_stream

  def show(conn, _params) do
    conn
    |> put_resp_header("cache-control", "public, max-age=2")
    |> json(LiveStreams.public_status(conn.assigns.live_stream))
  end

  def playlist(conn, _params) do
    stream = conn.assigns.live_stream

    case LiveStreams.playlist(stream) do
      {:ok, body} ->
        max_age = if stream.status == :ended, do: 30, else: 1

        conn
        |> put_resp_header("cache-control", "public, max-age=#{max_age}")
        |> put_resp_content_type("application/vnd.apple.mpegurl")
        |> send_resp(200, body)

      {:error, _reason} ->
        not_found(conn)
    end
  end

  def embed(conn, _params) do
    stream = conn.assigns.live_stream
    nonce = Base.url_encode64(:crypto.strong_rand_bytes(18), padding: false)
    base = String.replace_suffix(conn.request_path, "/embed", "")

    conn
    |> put_resp_header("content-security-policy", player_policy(stream, nonce))
    # Storage with hotlink protection checks the origin of segment requests.
    |> put_resp_header("referrer-policy", "strict-origin-when-cross-origin")
    |> put_resp_header("cache-control", "no-store")
    |> put_format("html")
    |> put_root_layout(false)
    |> put_layout(false)
    |> put_view(html: LivePlayerHTML)
    |> render(:page,
      name: stream.name,
      nonce: nonce,
      status_url: base,
      src: base <> "/index.m3u8",
      script: MaveCoreWeb.Endpoint.static_path("/assets/js/live_player.js")
    )
  end

  # The page runs one bundled script. The playlist comes from this origin and
  # the segments from the public media origin.
  defp player_policy(stream, nonce) do
    storage = LiveStreams.storage_origin(stream.space) || ""

    "default-src 'none'; base-uri 'none'; form-action 'none'; frame-ancestors *; " <>
      "script-src 'self'; style-src 'nonce-#{nonce}'; " <>
      "connect-src 'self' #{storage}; media-src 'self' blob: #{storage}"
  end

  defp load_stream(%{params: %{"id" => id}} = conn, _opts) do
    with %LiveStream{} = stream <- LiveStreams.get_by_public_id(id),
         true <- LiveStreams.available?(stream.space) do
      conn
      |> put_resp_header("x-content-type-options", "nosniff")
      |> assign(:live_stream, stream)
    else
      _ -> conn |> not_found() |> halt()
    end
  end

  defp not_found(conn) do
    conn
    |> put_resp_header("cache-control", "public, max-age=2")
    |> put_status(:not_found)
    |> json(%{error: "This live stream is not available."})
  end
end
