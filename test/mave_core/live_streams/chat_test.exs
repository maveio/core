defmodule MaveCore.LiveStreams.ChatTest do
  use MaveCore.DataCase, async: false

  import MaveCore.LiveStreamsFixtures

  alias MaveCore.LiveStreams
  alias MaveCore.LiveStreams.Chat

  setup do
    enable_live_streams(chat_refresh_ms: 20)
    space = space_fixture()
    stream = %{live_stream_fixture(space, %{name: "Town hall"}) | space: space}

    %{space: space, stream: stream}
  end

  defp live(%{stream: stream, space: space}) do
    stream = %{broadcast_fixture(stream, 2) | space: space}
    Chat.subscribe(stream.id)
    assert {:ok, %{messages: [], status: %{status: :live, playable: true}}} = Chat.join(stream)
    %{stream: stream, id: stream.id}
  end

  test "a chat is open only while a broadcast runs", %{stream: stream, space: space} do
    refute Chat.open?(stream)
    assert {:error, :closed} = Chat.join(stream)
    assert {:error, :closed} = Chat.post(stream.id, "viewer", "Ada", "hello", false)

    live = %{broadcast_fixture(stream, 1) | space: space}
    assert Chat.open?(live)
    assert {:ok, %{messages: [], status: %{status: :live, broadcast: 1}}} = Chat.join(live)

    # The broadcast may still resume within the reconnect window.
    LiveStreams.end_session(live)
    assert Chat.open?(LiveStreams.get(space, live.id))
  end

  describe "during a broadcast" do
    setup :live

    test "messages reach subscribers and those who join later", %{stream: stream, id: id} do
      assert :ok = Chat.post(id, "a", "  Ada ", " Hello everyone\n", false)

      assert_receive {:chat_message,
                      %{id: 1, name: "Ada", text: "Hello everyone", question: false} = message}

      assert %DateTime{} = message.at
      assert {:ok, %{messages: [^message]}} = Chat.join(stream)
    end

    test "a name and a text have limits", %{id: id} do
      assert {:error, :invalid} = Chat.post(id, "a", "", "hello", false)
      assert {:error, :invalid} = Chat.post(id, "a", "   ", "hello", false)
      assert {:error, :invalid} = Chat.post(id, "a", String.duplicate("n", 33), "hello", false)
      assert {:error, :invalid} = Chat.post(id, "a", "Ada", "", false)
      assert {:error, :invalid} = Chat.post(id, "a", "Ada", String.duplicate("x", 501), false)
      assert {:error, :invalid} = Chat.post(id, "a", "Ada", nil, false)

      assert :ok =
               Chat.post(id, "a", String.duplicate("n", 32), String.duplicate("x", 500), false)

      refute_received {:chat_message, %{id: 2}}
    end

    test "a viewer who posts too fast is held back, others are not", %{id: id} do
      for _ <- 1..5, do: assert(:ok = Chat.post(id, "a", "Ada", "hello", false))

      assert {:error, :rate_limited} = Chat.post(id, "a", "Ada", "again", false)
      assert :ok = Chat.post(id, "b", "Grace", "hello", false)
    end

    test "a question collects one vote per viewer", %{stream: stream, id: id} do
      :ok = Chat.post(id, "a", "Ada", "What is next?", true)
      :ok = Chat.post(id, "a", "Ada", "Not a question", false)
      assert_receive {:chat_message, %{id: question, question: true}}
      assert_receive {:chat_message, %{id: statement, question: false}}

      assert :ok = Chat.vote(id, "b", question)
      assert_receive {:chat_message, %{id: ^question, voters: voters}}
      assert MapSet.to_list(voters) == ["b"]

      # A second vote of the same viewer takes the first one back.
      assert :ok = Chat.vote(id, "b", question)
      assert_receive {:chat_message, %{id: ^question, voters: voters}}
      assert MapSet.size(voters) == 0

      :ok = Chat.vote(id, "b", question)
      :ok = Chat.vote(id, "c", question)
      assert {:ok, %{messages: [%{voters: voters}, _statement]}} = Chat.join(stream)
      assert MapSet.size(voters) == 2

      assert {:error, :not_found} = Chat.vote(id, "b", statement)
      assert {:error, :not_found} = Chat.vote(id, "b", 99)

      # Votes reach every viewer, so one viewer cannot keep toggling.
      for _ <- 1..15, do: Chat.vote(id, "b", question)
      assert {:error, :rate_limited} = Chat.vote(id, "b", question)
      assert :ok = Chat.vote(id, "d", question)
    end

    test "the room keeps the 100 most recent messages", %{stream: stream, id: id} do
      for n <- 1..105, do: :ok = Chat.post(id, "viewer-#{n}", "Viewer", "message #{n}", false)

      assert {:ok, %{messages: messages}} = Chat.join(stream)
      assert length(messages) == 100
      assert hd(messages).text == "message 6"
      assert List.last(messages).text == "message 105"
    end

    test "participants are counted once per viewer", %{id: id} do
      assert Chat.participants(id) == 0

      assert :ok = Chat.track(self(), id, "a")
      assert :ok = Chat.track(self(), id, "a")
      assert_receive %Phoenix.Socket.Broadcast{event: "presence_diff"}
      assert Chat.participants(id) == 1

      other = spawn_link(fn -> Process.sleep(:infinity) end)
      assert :ok = Chat.track(other, id, "b")
      assert Chat.participants(id) == 2

      assert :ok = Chat.untrack(self(), id, "a")
      assert Chat.participants(id) == 1
    end

    test "the room reports the stream's status to its viewers", %{stream: stream} do
      LiveStreams.end_session(stream)
      assert_receive {:chat_status, %{status: :disconnected, playable: true}}

      {:ok, _stream, _position} = LiveStreams.begin_session(stream)
      assert_receive {:chat_status, %{status: :live}}
    end

    test "the end of the broadcast closes the chat and drops its messages", %{
      stream: stream,
      space: space,
      id: id
    } do
      :ok = Chat.post(id, "a", "Ada", "A question?", true)

      LiveStreams.end_session(stream)
      LiveStreams.end_broadcast(stream)

      assert_receive {:chat_closed, %{status: :ended, playable: true}}

      assert eventually(fn ->
               Chat.post(id, "a", "Ada", "anyone?", false) == {:error, :closed}
             end)

      assert {:error, :closed} = Chat.vote(id, "b", 1)
      assert {:error, :closed} = Chat.join(%{LiveStreams.get(space, id) | space: space})

      # The next broadcast starts with an empty chat.
      next = %{broadcast_fixture(stream, 2) | space: space}
      assert {:ok, %{messages: [], status: %{broadcast: 2}}} = Chat.join(next)
    end

    test "a deleted stream closes the chat", %{stream: stream, id: id} do
      {:ok, _deleted} = LiveStreams.delete(stream)

      assert_receive {:chat_closed, %{status: :ended, playable: false}}

      assert eventually(fn ->
               Chat.post(id, "a", "Ada", "anyone?", false) == {:error, :closed}
             end)
    end
  end
end
