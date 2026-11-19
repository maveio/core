defmodule MaveCoreWeb.Live.Dashboard.LiveStreamsTest do
  use MaveCoreWeb.ConnCase, async: false

  import MaveCore.LiveStreamsFixtures
  import Phoenix.LiveViewTest

  alias MaveCore.Accounts
  alias MaveCore.LiveStreams

  setup %{conn: conn} do
    enable_live_streams(reconnect_seconds: 60)

    email = "live-ui-#{System.unique_integer([:positive])}@example.com"
    {:ok, user} = Accounts.create_user(email)
    login_token = Accounts.generate_user_login_token(user)
    {:ok, {user, persisted_login_token}} = Accounts.login_user(login_token)
    session_token = Accounts.generate_user_session_token(persisted_login_token, user)

    conn =
      case System.get_env("MAVE_MANAGE_HOST") do
        host when is_binary(host) and host != "" -> %{conn | host: host}
        _ -> conn
      end

    %{
      conn: init_test_session(conn, user_token: session_token),
      space: user.current_space_membership.space
    }
  end

  test "the first stream is created from the empty state", %{conn: conn, space: space} do
    {:ok, view, html} = live(conn, "/live")

    assert html =~ "Go live from OBS"
    assert has_element?(view, "#live-empty-create-button")
    refute has_element?(view, "#live-streams")

    {:error, {:live_redirect, %{to: to}}} =
      view |> element("#live-empty-create-button") |> render_click()

    assert [stream] = LiveStreams.list(space)
    assert to == "/live/#{stream.id}"
  end

  test "the list follows the status of its streams", %{conn: conn, space: space} do
    stream = live_stream_fixture(space, %{name: "Town hall"})
    {:ok, view, _html} = live(conn, "/live")

    assert has_element?(view, "#live-create-button")
    assert has_element?(view, "#live-stream-#{stream.id}", "Town hall")
    assert has_element?(view, "#live-stream-#{stream.id}", "Never streamed")

    broadcast_fixture(stream, 1)

    assert render(view) =~ "Started"
    assert has_element?(view, "#live-stream-#{stream.id}", "Live")
  end

  test "the stream page shows what the encoder needs and masks the key", %{
    conn: conn,
    space: space
  } do
    stream = live_stream_fixture(space, %{name: "Town hall"})
    {:ok, view, html} = live(conn, "/live/#{stream.id}")

    assert has_element?(view, "#live-stream-status", "Offline")
    assert has_element?(view, "#live-stream-summary", "Waiting for the encoder")
    assert has_element?(view, "#live-stream-server")
    assert html =~ LiveStreams.ingest_url()
    assert html =~ "/live/#{space.hash}#{stream.hash}/index.m3u8"
    assert has_element?(view, "#live-stream-watch", "/watch/#{space.hash}#{stream.hash}")

    assert has_element?(
             view,
             ~s(#live-stream-watch-link[href$="/watch/#{space.hash}#{stream.hash}"])
           )

    assert has_element?(
             view,
             ~s(#live-stream-preview iframe[src$="/live/#{space.hash}#{stream.hash}/embed"])
           )

    # The key is masked until it is revealed; copying works either way.
    refute has_element?(view, "#live-stream-key", stream.stream_key)
    assert has_element?(view, "#live-stream-key-copy-value", stream.stream_key)

    view |> element("#live-stream-key-toggle") |> render_click()
    assert has_element?(view, "#live-stream-key", stream.stream_key)
  end

  test "the stream page follows a broadcast until it ends", %{conn: conn, space: space} do
    stream = live_stream_fixture(space)
    {:ok, view, _html} = live(conn, "/live/#{stream.id}")

    stream = broadcast_fixture(stream, 2)
    {:ok, _stream} = LiveStreams.put_ingest(stream, %{"width" => 1280, "height" => 720})

    assert has_element?(view, "#live-stream-status", "Live")
    assert has_element?(view, "#live-stream-summary", "Live for")
    assert render(view) =~ "1280×720"
    refute has_element?(view, "#live-stream-end-button")

    LiveStreams.end_session(stream, "The encoder sent HEVC video")

    assert has_element?(view, "#live-stream-status", "Reconnecting")
    assert has_element?(view, "#live-stream-summary", "reconnects within")
    assert has_element?(view, "#live-stream-error", "The encoder sent HEVC video")

    view |> element("#live-stream-end-button") |> render_click()

    assert has_element?(view, "#live-stream-status", "Ended")
    assert has_element?(view, "#live-stream-summary", "The broadcast ended. 0:04 recorded.")
  end

  test "the key is replaced and the stream deleted after confirming", %{conn: conn, space: space} do
    stream = live_stream_fixture(space)
    {:ok, view, _html} = live(conn, "/live/#{stream.id}")

    view |> element("#live-stream-reset-key-button") |> render_click()
    assert render(view) =~ "Replace the stream key?"
    render_click(view, "confirmed")

    assert LiveStreams.get(space, stream.id).stream_key != stream.stream_key
    assert render(view) =~ "Stream key replaced"

    view |> element("#live-stream-delete-button") |> render_click()
    assert render(view) =~ "Delete this live stream?"

    assert {:error, {:live_redirect, %{to: "/live"}}} = render_click(view, "confirmed")
    assert LiveStreams.list(space) == []
  end

  test "the stream is renamed from its title", %{conn: conn, space: space} do
    stream = live_stream_fixture(space)
    {:ok, view, _html} = live(conn, "/live/#{stream.id}")

    render_change(view, "rename", %{"rename" => %{"name" => "Launch"}})

    assert LiveStreams.get(space, stream.id).name == "Launch"
  end

  test "without live streaming the pages and the navigation item are gone", %{
    conn: conn,
    space: space
  } do
    stream = live_stream_fixture(space)

    {:ok, view, _html} = live(conn, "/videos")
    assert has_element?(view, ~s(#sidebar a[href$="/live"]), "Live")

    Application.put_env(:mave_core, :live_streams, enabled: false)

    {:ok, view, _html} = live(conn, "/videos")
    refute has_element?(view, ~s(#sidebar a[href$="/live"]))

    assert {:error, {:live_redirect, %{to: to}}} = live(conn, "/live")
    assert String.ends_with?(to, "/videos")
    assert {:error, {:live_redirect, %{to: "/live"}}} = live(conn, "/live/#{stream.id}")
  end

  test "a stream of another space is not shown", %{conn: conn} do
    stream = live_stream_fixture(space_fixture())

    assert {:error, {:live_redirect, %{to: "/live"}}} = live(conn, "/live/#{stream.id}")
  end
end
