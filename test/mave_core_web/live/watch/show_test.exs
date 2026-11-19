defmodule MaveCoreWeb.Watch.ShowTest do
  use MaveCoreWeb.ConnCase, async: false

  import MaveCore.LiveStreamsFixtures
  import Phoenix.LiveViewTest

  alias MaveCore.LiveStreams
  alias MaveCore.LiveStreams.Chat
  alias MaveCoreWeb.Plugs.ViewerSession

  setup do
    enable_live_streams(chat_refresh_ms: 20)
    space = space_fixture()
    stream = live_stream_fixture(space, %{name: "Town hall"})

    %{space: space, stream: stream, path: "/watch/#{LiveStreams.public_id(space, stream)}"}
  end

  # Every visitor is a browser of its own.
  defp visitor do
    case System.get_env("MAVE_MANAGE_HOST") do
      host when is_binary(host) and host != "" -> %{build_conn() | host: host}
      _ -> build_conn()
    end
  end

  defp join_chat(view, name) do
    view |> form("#watch-name-form", %{name: name}) |> render_submit()
  end

  defp say(view, params) do
    view |> form("#watch-message-form", params) |> render_submit()
  end

  test "a stream that does not exist or may not stream has no watch page", %{
    space: space,
    path: path
  } do
    assert_error_sent 404, fn -> get(visitor(), "/watch/#{space.hash}unknownhash") end
    assert_error_sent 404, fn -> get(visitor(), "/watch/nope") end

    Application.put_env(:mave_core, :live_streams, enabled: false)
    assert_error_sent 404, fn -> get(visitor(), path) end
  end

  test "an offline stream shows the player and a closed chat", %{path: path} do
    conn = get(visitor(), path)
    html = html_response(conn, 200)

    assert html =~ "<title"
    assert html =~ "Town hall"
    assert html =~ "/assets/js/live_watch.js"
    assert html =~ ~s(name="robots" content="noindex")
    assert <<_::binary-size(24)>> = get_session(conn, ViewerSession.key())

    {:ok, view, _html} = live(conn)

    assert has_element?(view, "#watch-title", "Town hall")

    assert has_element?(
             view,
             ~s(#watch-player[phx-hook=live_player][phx-update=ignore][data-status=idle][data-playable=false])
           )

    assert has_element?(
             view,
             ~s(#watch-player[data-src$="#{path |> Path.basename()}/index.m3u8"])
           )

    assert has_element?(view, "#watch-player [data-notice]", "This stream is offline.")
    assert has_element?(view, "#watch-chat-closed", "opens when the broadcast starts")
    assert has_element?(view, "#watch-participants", "0")
    assert has_element?(view, "#watch-messages-empty[hidden]")
    refute has_element?(view, "#watch-name-form")
    refute has_element?(view, "#watch-message-form")

    # Without a chat nothing is accepted.
    render_hook(view, "set_name", %{"name" => "Ada"})
    render_hook(view, "send_message", %{"text" => "hello"})
    refute has_element?(view, "#watch-message-form")
  end

  test "a visitor keeps the same viewer id", %{path: path} do
    conn = get(visitor(), path)
    viewer = get_session(conn, ViewerSession.key())

    again = conn |> recycle() |> Map.put(:host, conn.host) |> get(path)
    assert get_session(again, ViewerSession.key()) == viewer

    refute get_session(get(visitor(), path), ViewerSession.key()) == viewer
  end

  describe "during a broadcast" do
    setup %{stream: stream} do
      %{stream: broadcast_fixture(stream, 2)}
    end

    test "a viewer picks a name, chats, asks a question and votes", %{path: path} do
      {:ok, view, _html} = live(visitor(), path)

      assert has_element?(view, "#watch-player[data-status=live][data-playable=true]")
      assert has_element?(view, "#watch-messages-empty:not([hidden])")
      refute has_element?(view, "#watch-message-form")

      join_chat(view, "   ")
      assert has_element?(view, "#watch-chat-error", "Choose a name of 1 to 32 characters.")

      join_chat(view, " Ada ")
      refute has_element?(view, "#watch-chat-error")
      assert_push_event(view, "chat_name_saved", %{name: "Ada"})
      assert has_element?(view, "#watch-message-form[phx-hook=chat_composer]")

      say(view, %{text: "<script>alert(1)</script>", question: "true"})
      assert_push_event(view, "chat_message_sent", %{})

      assert render(view) =~ "&lt;script&gt;alert(1)&lt;/script&gt;"
      refute has_element?(view, "#watch-messages script")
      assert has_element?(view, "#watch-message-1 strong", "Ada")
      assert has_element?(view, "#watch-message-1 time[datetime]")
      assert has_element?(view, "#watch-message-1 [data-vote][aria-pressed=false]", "0")

      view |> element("#watch-message-1 [data-vote]") |> render_click()
      assert has_element?(view, "#watch-message-1 [data-vote][aria-pressed=true]", "1")

      view |> element("#watch-message-1 [data-vote]") |> render_click()
      assert has_element?(view, "#watch-message-1 [data-vote][aria-pressed=false]", "0")

      say(view, %{text: "Just saying"})
      assert has_element?(view, "#watch-message-2", "Just saying")
      refute has_element?(view, "#watch-message-2 [data-vote]")

      render_hook(view, "send_message", %{"text" => String.duplicate("x", 501)})
      assert has_element?(view, "#watch-chat-error", "at most 500 characters")
    end

    test "viewers see each other's messages and votes and are counted", %{path: path} do
      {:ok, first, _html} = live(visitor(), path)
      {:ok, second, _html} = live(visitor(), path)

      join_chat(first, "Ada")
      say(first, %{text: "What is next?", question: "true"})

      assert has_element?(second, "#watch-message-1", "What is next?")

      # The second viewer votes without choosing a name.
      second |> element("#watch-message-1 [data-vote]") |> render_click()
      assert has_element?(second, "#watch-message-1 [data-vote][aria-pressed=true]", "1")
      assert has_element?(first, "#watch-message-1 [data-vote][aria-pressed=false]", "1")

      assert eventually(fn -> has_element?(first, "#watch-participants", "2") end)
      assert eventually(fn -> has_element?(second, "#watch-participants", "2") end)

      # Someone who arrives later gets the conversation so far.
      {:ok, third, _html} = live(visitor(), path)
      assert has_element?(third, "#watch-message-1 [data-vote][aria-pressed=false]", "1")

      stop_live_view(second)
      stop_live_view(third)
      assert eventually(fn -> has_element?(first, "#watch-participants", "1") end)
    end

    test "a viewer who posts too fast is asked to slow down", %{path: path} do
      {:ok, view, _html} = live(visitor(), path)
      join_chat(view, "Ada")

      for n <- 1..5, do: say(view, %{text: "message #{n}"})
      refute has_element?(view, "#watch-chat-error")

      say(view, %{text: "one too many"})
      assert has_element?(view, "#watch-chat-error", "Slow down")
      refute render(view) =~ "one too many"
    end

    test "the chat closes and forgets its messages when the broadcast ends", %{
      stream: stream,
      path: path
    } do
      {:ok, view, _html} = live(visitor(), path)
      join_chat(view, "Ada")
      say(view, %{text: "Temporary"})
      assert has_element?(view, "#watch-message-1", "Temporary")

      LiveStreams.end_session(stream)
      assert eventually(fn -> has_element?(view, "#watch-player[data-status=disconnected]") end)
      assert has_element?(view, "#watch-message-form")

      LiveStreams.end_broadcast(stream)
      assert eventually(fn -> has_element?(view, "#watch-chat-closed", "closed when") end)

      assert has_element?(view, "#watch-player[data-status=ended][data-playable=true]")
      assert has_element?(view, "#watch-participants", "0")
      assert has_element?(view, "#watch-messages-empty[hidden]")
      refute render(view) =~ "Temporary"
      refute has_element?(view, "#watch-message-form")
    end
  end

  test "the page follows the stream from offline into a broadcast", %{
    space: space,
    stream: stream,
    path: path
  } do
    {:ok, view, _html} = live(visitor(), path)
    assert has_element?(view, "#watch-chat-closed")

    {:ok, _stream} = LiveStreams.update(stream, %{name: "All hands"})
    assert has_element?(view, "#watch-title", "All hands")
    assert page_title(view) =~ "All hands"

    # The encoder connects; the player waits for the first segments.
    stream = broadcast_fixture(stream, 1)
    assert has_element?(view, "#watch-player[data-status=live][data-playable=false]")
    assert has_element?(view, "#watch-name-form")

    broadcast_fixture(stream, 1)
    assert eventually(fn -> has_element?(view, "#watch-player[data-playable=true]") end)

    {:ok, _deleted} = LiveStreams.delete(%{stream | space: space})
    assert eventually(fn -> has_element?(view, "#watch-chat-closed") end)
    assert {:error, :closed} = Chat.post(stream.id, "viewer", "Ada", "hello", false)
  end

  test "the address of a deleted stream stops working", %{
    space: space,
    stream: stream,
    path: path
  } do
    {:ok, view, _html} = live(visitor(), path)

    {:ok, _deleted} = LiveStreams.delete(%{stream | space: space})
    assert_redirect(view, path)
  end
end
