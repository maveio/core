defmodule MaveCore.LiveStreams.Chat do
  @moduledoc """
  Chat beside a live stream on its watch page.

  A chat is open while a broadcast runs, including its reconnect window.
  Viewers pick a name, post messages and mark a message as a question that
  others can vote for. Messages are kept in memory by one room process per
  stream and are dropped when the broadcast ends. See `docs/live_streaming.md`.
  """

  alias MaveCore.LiveStreams.Chat.{Presence, Room}
  alias MaveCore.LiveStreams.LiveStream

  @name_length 32
  @text_length 500

  def name_length, do: @name_length
  def text_length, do: @text_length

  @doc "Whether viewers can chat: a broadcast is running or may still resume."
  def open?(%LiveStream{status: status}), do: status in [:live, :disconnected]
  def open?(_stream), do: false

  @doc """
  Subscribes to the chat of a stream. The subscriber receives
  `{:chat_message, message}` for a new or changed message,
  `{:chat_status, status}` when the stream's public status changes and
  `{:chat_closed, status}` when the broadcast ended and the messages are gone.
  Presence changes arrive as `Phoenix.Socket.Broadcast` with the event
  `"presence_diff"`.
  """
  def subscribe(stream_id) when is_binary(stream_id),
    do: Phoenix.PubSub.subscribe(MaveCore.PubSub, topic(stream_id))

  @doc "Opens the chat of a stream and returns its messages and public status."
  def join(%LiveStream{id: id, space: %{id: _} = space}) do
    with :ok <- Room.ensure_started(id, space), do: Room.join(id)
  end

  @doc """
  Posts a message as `viewer`. Returns `{:error, :invalid}` for a name or text
  outside the limits, `{:error, :rate_limited}` for a viewer who posts too fast
  and `{:error, :closed}` when the chat is not open.
  """
  def post(stream_id, viewer, name, text, question?) when is_binary(viewer) do
    with {:ok, name} <- cast(name, @name_length),
         {:ok, text} <- cast(text, @text_length) do
      Room.post(stream_id, viewer, name, text, question? == true)
    end
  end

  @doc """
  Adds or removes the vote of `viewer` for a question. Returns
  `{:error, :not_found}` for a message that is gone or is not a question.
  """
  def vote(stream_id, viewer, message_id) when is_binary(viewer) and is_integer(message_id),
    do: Room.vote(stream_id, viewer, message_id)

  @doc "Validates the name a viewer chats under."
  def cast_name(name), do: cast(name, @name_length)

  @doc "Counts `pid` as a participant for as long as it lives."
  def track(pid, stream_id, viewer) when is_pid(pid) and is_binary(viewer) do
    case Presence.track(pid, topic(stream_id), viewer, %{}) do
      {:ok, _ref} -> :ok
      {:error, {:already_tracked, _pid, _topic, _key}} -> :ok
      {:error, _reason} = error -> error
    end
  end

  def untrack(pid, stream_id, viewer) when is_pid(pid) and is_binary(viewer),
    do: Presence.untrack(pid, topic(stream_id), viewer)

  @doc "Number of distinct viewers who are in the chat."
  def participants(stream_id), do: stream_id |> topic() |> Presence.list() |> map_size()

  @doc false
  def broadcast(stream_id, message),
    do: Phoenix.PubSub.broadcast(MaveCore.PubSub, topic(stream_id), message)

  defp topic(stream_id), do: "live_streams:chat:" <> stream_id

  defp cast(value, max) when is_binary(value) do
    value = String.trim(value)

    if String.valid?(value) and String.length(value) in 1..max,
      do: {:ok, value},
      else: {:error, :invalid}
  end

  defp cast(_value, _max), do: {:error, :invalid}
end
