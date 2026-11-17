defmodule MaveCore.LiveStreams.Chat.Room do
  @moduledoc """
  The chat of one broadcast. The room starts with the first viewer, keeps the
  most recent messages in memory and follows the stream so every viewer hears
  about status changes from one place. It stops, and its messages are gone,
  when the broadcast ends.

  The name is registered globally: a cluster has one room per stream.
  """

  use GenServer, restart: :temporary

  alias MaveCore.LiveStreams
  alias MaveCore.LiveStreams.{Chat, Config, LiveStream}

  @history 100
  # What one viewer may do per window. Every post and vote goes to all viewers.
  @rate_limits %{post: 5, vote: 20}
  @rate_window_ms 10_000
  @max_misses 15
  @call_timeout 5_000

  def start_link({stream_id, _space} = arg),
    do: GenServer.start_link(__MODULE__, arg, name: name(stream_id))

  @doc "Starts the room of a stream whose chat is open, unless it runs already."
  def ensure_started(stream_id, space) do
    if GenServer.whereis(name(stream_id)) do
      :ok
    else
      case DynamicSupervisor.start_child(
             MaveCore.LiveStreams.ChatSupervisor,
             {__MODULE__, {stream_id, space}}
           ) do
        {:ok, _pid} -> :ok
        {:error, {:already_started, _pid}} -> :ok
        _closed -> {:error, :closed}
      end
    end
  end

  def join(stream_id), do: call(stream_id, :join)

  def post(stream_id, viewer, name, text, question?),
    do: call(stream_id, {:post, viewer, name, text, question?})

  def vote(stream_id, viewer, message_id), do: call(stream_id, {:vote, viewer, message_id})

  defp call(stream_id, request) do
    GenServer.call(name(stream_id), request, @call_timeout)
  catch
    :exit, _reason -> {:error, :closed}
  end

  defp name(stream_id), do: {:global, {__MODULE__, stream_id}}

  # ---------------------------------------------------------------------------
  # Server
  # ---------------------------------------------------------------------------

  @impl true
  def init({stream_id, space}) do
    case LiveStreams.get(space, stream_id) do
      %LiveStream{} = stream ->
        if Chat.open?(stream) do
          LiveStreams.subscribe(space.id)
          schedule_refresh()

          {:ok,
           %{
             id: stream.id,
             space: space,
             broadcast: stream.broadcast,
             status: LiveStreams.public_status(stream),
             messages: [],
             rates: %{},
             sequence: 0,
             misses: 0
           }}
        else
          :ignore
        end

      nil ->
        :ignore
    end
  end

  @impl true
  def handle_call(:join, _from, state),
    do: {:reply, {:ok, %{messages: state.messages, status: state.status}}, state}

  def handle_call({:post, viewer, name, text, question?}, _from, state),
    do: limited(state, :post, viewer, &add_message(&1, viewer, name, text, question?))

  def handle_call({:vote, viewer, message_id}, _from, state),
    do: limited(state, :vote, viewer, &toggle_vote(&1, viewer, message_id))

  defp limited(state, action, viewer, fun) do
    now = System.monotonic_time(:millisecond)
    key = {action, viewer}
    recent = state.rates |> Map.get(key, []) |> Enum.filter(&(now - &1 < @rate_window_ms))

    if length(recent) >= @rate_limits[action],
      do: {:reply, {:error, :rate_limited}, put_in(state.rates[key], recent)},
      else: fun.(put_in(state.rates[key], [now | recent]))
  end

  defp add_message(state, viewer, name, text, question?) do
    message = %{
      id: state.sequence + 1,
      viewer: viewer,
      name: name,
      text: text,
      question: question?,
      at: DateTime.utc_now(:second),
      voters: MapSet.new()
    }

    Chat.broadcast(state.id, {:chat_message, message})

    messages = Enum.take(state.messages ++ [message], -@history)
    {:reply, :ok, %{state | sequence: message.id, messages: messages}}
  end

  defp toggle_vote(state, viewer, message_id) do
    case Enum.find(state.messages, &(&1.id == message_id and &1.question)) do
      nil ->
        {:reply, {:error, :not_found}, state}

      message ->
        voters =
          if MapSet.member?(message.voters, viewer),
            do: MapSet.delete(message.voters, viewer),
            else: MapSet.put(message.voters, viewer)

        message = %{message | voters: voters}
        Chat.broadcast(state.id, {:chat_message, message})

        messages = Enum.map(state.messages, &if(&1.id == message_id, do: message, else: &1))
        {:reply, :ok, %{state | messages: messages}}
    end
  end

  @impl true
  def handle_info(:refresh, state) do
    schedule_refresh()
    refresh(%{state | rates: prune(state.rates)})
  end

  def handle_info({:live_stream_updated, id}, %{id: id} = state), do: refresh(state)
  def handle_info(_message, state), do: {:noreply, state}

  # Every viewer learns about the stream from the room, so a broadcast costs
  # one status query per interval instead of one per viewer.
  defp refresh(state) do
    case load(state) do
      {:ok, %LiveStream{broadcast: broadcast} = stream, status}
      when broadcast == state.broadcast ->
        cond do
          not Chat.open?(stream) ->
            close(state, status)

          status != state.status ->
            Chat.broadcast(state.id, {:chat_status, status})
            {:noreply, %{state | status: status, misses: 0}}

          true ->
            {:noreply, %{state | misses: 0}}
        end

      # Another broadcast started: its chat starts empty.
      {:ok, %LiveStream{}, status} ->
        close(state, status)

      {:ok, nil, nil} ->
        close(state, %{state.status | status: :ended, playable: false})

      :error when state.misses + 1 >= @max_misses ->
        close(state, %{state.status | status: :ended})

      :error ->
        {:noreply, %{state | misses: state.misses + 1}}
    end
  end

  defp load(state) do
    case LiveStreams.get(state.space, state.id) do
      %LiveStream{} = stream -> {:ok, stream, LiveStreams.public_status(stream)}
      nil -> {:ok, nil, nil}
    end
  rescue
    # The database may be briefly unavailable; the next refresh retries.
    _error -> :error
  end

  defp close(state, status) do
    Chat.broadcast(state.id, {:chat_closed, status})
    {:stop, :normal, state}
  end

  defp prune(rates) do
    now = System.monotonic_time(:millisecond)

    rates
    |> Map.new(fn {key, times} -> {key, Enum.filter(times, &(now - &1 < @rate_window_ms))} end)
    |> Map.reject(fn {_key, times} -> times == [] end)
  end

  defp schedule_refresh, do: Process.send_after(self(), :refresh, Config.get(:chat_refresh_ms))
end
