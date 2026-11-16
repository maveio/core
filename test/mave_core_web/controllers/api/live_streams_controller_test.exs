defmodule MaveCoreWeb.Api.LiveStreamsControllerTest do
  use MaveCoreWeb.ConnCase, async: false

  import MaveCore.LiveStreamsFixtures

  alias MaveCore.Accounts
  alias MaveCore.LiveStreams
  alias MaveCore.Spaces

  setup do
    enable_live_streams()

    {:ok, user} =
      Accounts.create_user("api-live-#{System.unique_integer([:positive])}@example.com")

    space = user.current_space_membership.space
    {:ok, key} = Spaces.create_key(space)
    auth = "Bearer " <> Spaces.display_api_key(key.key, key.secret)

    %{space: space, key: key, auth: auth}
  end

  defp api(auth), do: put_req_header(build_conn(), "authorization", auth)

  test "creates a stream and returns where to publish and where to watch", %{
    auth: auth,
    space: space
  } do
    conn = post(api(auth), ~p"/api/v1/live_streams", %{"name" => "Town hall"})

    assert %{
             "object" => "live_stream",
             "id" => id,
             "name" => "Town hall",
             "status" => "idle",
             "ingest" => %{"url" => "rtmp://" <> _, "stream_key" => "live_" <> _},
             "playback" => %{"hls" => hls, "player" => player, "embed" => "<iframe " <> _}
           } = json_response(conn, 201)

    assert String.starts_with?(id, space.hash)
    assert hls =~ "/live/#{id}/index.m3u8"
    assert player =~ "/live/#{id}/embed"

    assert %{"object" => "list", "data" => [%{"id" => ^id}]} =
             api(auth) |> get(~p"/api/v1/live_streams") |> json_response(200)

    assert %{"id" => ^id} = api(auth) |> get(~p"/api/v1/live_streams/#{id}") |> json_response(200)
  end

  test "renames a stream, replaces its key and deletes it", %{auth: auth, space: space} do
    stream = live_stream_fixture(space)
    id = LiveStreams.public_id(space, stream)

    assert %{"name" => "Renamed"} =
             api(auth)
             |> put(~p"/api/v1/live_streams/#{id}", %{"name" => "Renamed", "status" => "live"})
             |> json_response(200)

    assert %{"error" => _} =
             api(auth)
             |> put(~p"/api/v1/live_streams/#{id}", %{"name" => String.duplicate("a", 161)})
             |> json_response(422)

    assert %{"ingest" => %{"stream_key" => replaced}, "status" => "idle"} =
             api(auth) |> post(~p"/api/v1/live_streams/#{id}/reset_key") |> json_response(200)

    assert replaced != stream.stream_key

    assert api(auth) |> delete(~p"/api/v1/live_streams/#{id}") |> response(204) == ""
    assert api(auth) |> get(~p"/api/v1/live_streams/#{id}") |> json_response(404)
  end

  test "streams of another space are not reachable", %{auth: auth} do
    other = space_fixture()
    stream = live_stream_fixture(other)

    assert api(auth)
           |> get(~p"/api/v1/live_streams/#{LiveStreams.public_id(other, stream)}")
           |> json_response(404)

    assert api(auth) |> delete(~p"/api/v1/live_streams/#{stream.id}") |> json_response(404)
    assert LiveStreams.get(other, stream.id)
  end

  test "needs an API key, and a writable one to change streams", %{
    auth: auth,
    key: key,
    space: space
  } do
    assert build_conn() |> get(~p"/api/v1/live_streams") |> response(401)

    stream = live_stream_fixture(space)
    {:ok, _key} = Spaces.make_key_read_only(key)

    assert %{"data" => [_stream]} =
             api(auth) |> get(~p"/api/v1/live_streams") |> json_response(200)

    assert %{"error" => "This API key is read-only"} =
             api(auth) |> post(~p"/api/v1/live_streams", %{}) |> json_response(403)

    assert api(auth)
           |> post(~p"/api/v1/live_streams/#{stream.id}/reset_key")
           |> json_response(403)

    assert api(auth) |> delete(~p"/api/v1/live_streams/#{stream.id}") |> json_response(403)
  end

  test "answers 403 when live streaming is not available", %{auth: auth} do
    Application.put_env(:mave_core, :live_streams, enabled: false)

    assert %{"error" => "Live streaming is not available for this space."} =
             api(auth) |> get(~p"/api/v1/live_streams") |> json_response(403)

    assert api(auth) |> post(~p"/api/v1/live_streams", %{}) |> json_response(403)
  end
end
