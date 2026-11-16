defmodule MaveCoreWeb.Api.LivePlaybackControllerTest do
  use MaveCoreWeb.ConnCase, async: false

  import MaveCore.LiveStreamsFixtures

  alias MaveCore.Embeds.SettingsSerializer
  alias MaveCore.LiveStreams

  setup do
    enable_live_streams()
    space = space_fixture()
    stream = live_stream_fixture(space, %{name: "Town hall"})

    %{space: space, stream: stream, id: LiveStreams.public_id(space, stream)}
  end

  test "a stream that never went live reports idle and has no playlist", %{conn: conn, id: id} do
    conn = get(conn, ~p"/api/v1/live/#{id}")

    assert %{"status" => "idle", "playable" => false, "name" => "Town hall", "broadcast" => 0} =
             json_response(conn, 200)

    assert get_resp_header(conn, "cache-control") == ["public, max-age=2"]

    assert %{"error" => _} =
             build_conn() |> get(~p"/api/v1/live/#{id}/index.m3u8") |> json_response(404)
  end

  test "a live broadcast serves a short-lived playlist of public media addresses", %{
    conn: conn,
    space: space,
    stream: stream,
    id: id
  } do
    broadcast_fixture(stream, 3)

    assert %{"status" => "live", "playable" => true, "broadcast" => 1} =
             conn |> get(~p"/api/v1/live/#{id}") |> json_response(200)

    conn = get(build_conn(), ~p"/api/v1/live/#{id}/index.m3u8")

    assert [content_type] = get_resp_header(conn, "content-type")
    assert content_type =~ "application/vnd.apple.mpegurl"
    assert get_resp_header(conn, "cache-control") == ["public, max-age=1"]

    segment =
      SettingsSerializer.storage_object_url(
        LiveStreams.bucket(space),
        "live/#{stream.hash}/1/2.ts"
      )

    assert response(conn, 200) =~ "#EXTINF:2.000,\n#{segment}\n"
    refute response(conn, 200) =~ "#EXT-X-ENDLIST"
  end

  test "an ended broadcast serves its recording", %{stream: stream, id: id} do
    stream = broadcast_fixture(stream, 2)
    LiveStreams.end_session(stream)
    LiveStreams.end_broadcast(stream)

    conn = get(build_conn(), ~p"/api/v1/live/#{id}/index.m3u8")

    assert get_resp_header(conn, "cache-control") == ["public, max-age=30"]
    assert response(conn, 200) =~ "#EXT-X-ENDLIST"

    assert %{"status" => "ended", "playable" => true} =
             build_conn() |> get(~p"/api/v1/live/#{id}") |> json_response(200)
  end

  test "the player page runs one script under a strict policy and may be embedded", %{
    space: space,
    id: id
  } do
    conn = get(build_conn(), ~p"/api/v1/live/#{id}/embed")
    html = html_response(conn, 200)

    assert html =~ ~s(id="live-player")
    assert html =~ ~s(data-status-url="/api/v1/live/#{id}")
    assert html =~ ~s(data-src="/api/v1/live/#{id}/index.m3u8")
    assert html =~ "/assets/js/live_player"
    assert html =~ "<title>Town hall</title>"

    assert [policy] = get_resp_header(conn, "content-security-policy")
    assert policy =~ "default-src 'none'"
    assert policy =~ "frame-ancestors *"
    assert policy =~ "script-src 'self';"
    assert policy =~ "media-src 'self' blob: #{LiveStreams.storage_origin(space)}"
    assert LiveStreams.storage_origin(space) =~ ~r{\Ahttps?://[^/]+\z}
    refute policy =~ "unsafe-inline"
    assert get_resp_header(conn, "x-frame-options") == []
  end

  test "the api host serves the same playback routes", %{id: id} do
    assert %{plug: MaveCoreWeb.Api.LivePlaybackController, plug_opts: :playlist} =
             Phoenix.Router.route_info(
               MaveCoreWeb.Router,
               "GET",
               "/api/v1/live/#{id}/index.m3u8",
               "localhost"
             )
  end

  test "unknown streams and spaces without live streaming answer 404", %{conn: conn, id: id} do
    assert conn |> get(~p"/api/v1/live/#{"aaaaa" <> "bbbbbbbbbb"}") |> json_response(404)
    assert build_conn() |> get(~p"/api/v1/live/nope") |> json_response(404)

    Application.put_env(:mave_core, :live_streams, enabled: false)

    assert build_conn() |> get(~p"/api/v1/live/#{id}") |> json_response(404)
    assert build_conn() |> get(~p"/api/v1/live/#{id}/embed") |> json_response(404)
  end
end
