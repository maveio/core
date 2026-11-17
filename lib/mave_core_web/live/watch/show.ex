defmodule MaveCoreWeb.Watch.Show do
  @moduledoc """
  The public watch page of a live stream: the player beside a chat that is open
  while a broadcast runs. Viewers are anonymous; `MaveCoreWeb.Plugs.ViewerSession`
  tells them apart.
  """

  use MaveCoreWeb, :live_view

  alias MaveCore.LiveStreams
  alias MaveCore.LiveStreams.{Chat, LiveStream}
  alias MaveCoreWeb.Plugs.ViewerSession

  defmodule NotFoundError do
    @moduledoc false
    defexception message: "this live stream is not available", plug_status: 404
  end

  @history 100

  def mount(%{"id" => public_id}, session, socket) do
    with %LiveStream{} = stream <- LiveStreams.get_by_public_id(public_id),
         true <- LiveStreams.available?(stream.space),
         viewer when is_binary(viewer) <- session[ViewerSession.key()] do
      socket =
        socket
        |> assign(:public_id, public_id)
        |> assign(:viewer, viewer)
        |> assign(:src, LiveStreams.playback_url(stream.space, stream))
        |> assign(:name, "")
        |> assign(:participants, 0)
        |> assign(:open, false)
        |> assign(:error, nil)
        |> assign(:connecting, not connected?(socket))
        |> assign_stream(stream, LiveStreams.public_status(stream))
        |> stream_configure(:messages, dom_id: &"watch-message-#{&1.id}")
        |> stream(:messages, [])

      if connected?(socket) do
        LiveStreams.subscribe(stream.space.id)
        Chat.subscribe(stream.id)
        {:ok, open_chat(socket)}
      else
        {:ok, socket}
      end
    else
      _ -> raise NotFoundError
    end
  end

  # While the chat is open its room reports the stream's status to all viewers.
  def handle_info({:live_stream_updated, id}, %{assigns: %{stream: %{id: id}, open: false}} = s),
    do: {:noreply, reload(s)}

  def handle_info({:chat_status, status}, socket), do: {:noreply, assign(socket, :status, status)}

  def handle_info({:chat_message, message}, %{assigns: %{open: true}} = socket),
    do: {:noreply, stream_insert(socket, :messages, message, limit: -@history)}

  def handle_info({:chat_closed, status}, socket) do
    Chat.untrack(self(), socket.assigns.stream.id, socket.assigns.viewer)

    socket =
      socket
      |> assign(open: false, participants: 0, error: nil, status: status)
      |> stream(:messages, [], reset: true)

    # The room also closes when the next broadcast started before it noticed
    # the end of its own.
    if status.status in [:live, :disconnected],
      do: {:noreply, reload(socket)},
      else: {:noreply, socket}
  end

  def handle_info(%Phoenix.Socket.Broadcast{event: "presence_diff"}, socket) do
    if socket.assigns.open,
      do: {:noreply, assign(socket, :participants, Chat.participants(socket.assigns.stream.id))},
      else: {:noreply, socket}
  end

  def handle_info(_message, socket), do: {:noreply, socket}

  def handle_event("set_name", %{"name" => name}, %{assigns: %{open: true}} = socket) do
    case Chat.cast_name(name) do
      {:ok, name} ->
        {:noreply,
         socket
         |> assign(name: name, error: nil)
         |> push_event("chat_name_saved", %{name: name})}

      {:error, :invalid} ->
        {:noreply,
         assign(
           socket,
           :error,
           gettext("Choose a name of 1 to %{max} characters.", max: Chat.name_length())
         )}
    end
  end

  def handle_event("send_message", params, %{assigns: %{open: true, name: name}} = socket)
      when name != "" do
    %{stream: stream, viewer: viewer} = socket.assigns

    case Chat.post(stream.id, viewer, name, params["text"], params["question"] == "true") do
      :ok ->
        {:noreply, socket |> assign(:error, nil) |> push_event("chat_message_sent", %{})}

      {:error, :rate_limited} ->
        {:noreply,
         assign(socket, :error, gettext("Slow down: at most 5 messages per 10 seconds."))}

      # The room is gone although nobody said so. Follow the stream again.
      {:error, :closed} ->
        {:noreply, socket |> close_chat() |> reload()}

      {:error, :invalid} ->
        {:noreply,
         assign(
           socket,
           :error,
           gettext("Write a message of at most %{max} characters.", max: Chat.text_length())
         )}
    end
  end

  def handle_event("vote", %{"id" => id}, %{assigns: %{open: true}} = socket) do
    with {message_id, ""} <- Integer.parse(id),
         :ok <- Chat.vote(socket.assigns.stream.id, socket.assigns.viewer, message_id) do
      {:noreply, assign(socket, :error, nil)}
    else
      {:error, :rate_limited} ->
        {:noreply, assign(socket, :error, gettext("Slow down: too many votes at once."))}

      _ ->
        {:noreply, assign(socket, :error, gettext("This question is no longer available."))}
    end
  end

  def handle_event(_event, _params, socket), do: {:noreply, socket}

  def render(assigns) do
    ~H"""
    <main
      id="watch"
      class="grid h-dvh grid-cols-1 grid-rows-[min(56.25vw,45dvh)_minmax(0,1fr)] md:grid-cols-[minmax(0,1fr)_20rem] md:grid-rows-1 2xl:grid-cols-[minmax(0,1fr)_22.5rem]"
    >
      <section class="relative min-h-0 min-w-0 bg-black" aria-label={gettext("Broadcast")}>
        <div
          id="watch-player"
          phx-hook="live_player"
          phx-update="ignore"
          class="relative h-full w-full overflow-hidden"
          data-src={@src}
          data-status={@status.status}
          data-broadcast={@status.broadcast}
          data-playable={to_string(@status.playable)}
          data-offline={gettext("This stream is offline.")}
          data-starting={gettext("The broadcast is starting.")}
          data-ended={gettext("This stream has ended.")}
          data-unavailable={gettext("This stream is not available.")}
        >
          <video
            class="absolute inset-0 h-full w-full bg-black object-contain"
            aria-label={gettext("Live stream")}
            controls
            playsinline
            hidden
          ></video>
          <div
            data-empty
            class="pointer-events-none absolute inset-0 flex flex-col items-center justify-center gap-3 px-6 text-center text-stone-500"
          >
            <.icon name="hero-video-camera" class="size-8" />
            <p data-notice role="status" class="text-sm">{notice(@status)}</p>
          </div>
          <div
            data-badge
            hidden
            class="absolute left-3 top-3 flex items-center gap-1.5 rounded bg-red-600 py-0.5 pl-2 pr-2.5 text-xs font-semibold tracking-wider text-white"
          >
            <span class="size-1.5 rounded-full bg-white"></span>{gettext("LIVE")}
          </div>
        </div>
      </section>

      <aside
        id="watch-chat"
        phx-hook="chat_name"
        data-stream={@public_id}
        aria-label={gettext("Live chat")}
        class="flex min-h-0 min-w-0 flex-col overflow-hidden border-t border-stone-800 bg-stone-900 md:border-l md:border-t-0"
      >
        <div class="flex items-center justify-between gap-3 border-b border-stone-800 px-4 py-4">
          <h1 id="watch-title" class="truncate text-sm font-medium text-stone-100">{@title}</h1>
          <span
            class="flex flex-none items-center gap-1.5 text-xs tabular-nums text-stone-400"
            title={gettext("Viewers in the chat")}
          >
            <.icon name="hero-users" class="size-3.5" />
            <span id="watch-participants" aria-live="polite">{@participants}</span>
          </span>
        </div>

        <div
          id="watch-connection"
          role="status"
          class="hidden border-b border-amber-900/50 px-4 py-2.5 text-xs text-amber-200/80 [.phx-error_&]:block"
        >
          {gettext("Reconnecting…")}
        </div>

        <div
          id="watch-chat-scroll"
          phx-hook="chat_scroll"
          role="log"
          aria-label={gettext("Chat messages")}
          aria-live="polite"
          class="min-h-0 flex-1 overflow-y-auto p-4 [scrollbar-color:var(--color-stone-700)_transparent] [scrollbar-width:thin]"
        >
          <div id="watch-messages" phx-update="stream" class="space-y-5">
            <%!-- A stream container keeps its other children, so this one is
            hidden instead of left out. --%>
            <p
              id="watch-messages-empty"
              hidden={not @open}
              class="hidden pt-1 text-center text-xs text-stone-500 only:block"
            >
              {gettext("No messages yet. Say hello.")}
            </p>
            <article :for={{dom_id, message} <- @streams.messages} id={dom_id}>
              <div class="flex items-baseline gap-2">
                <strong class="text-xs font-medium text-stone-100 [overflow-wrap:anywhere]">
                  {message.name}
                </strong>
                <time
                  datetime={DateTime.to_iso8601(message.at)}
                  class="whitespace-nowrap text-[10px] text-stone-500"
                >
                  {Calendar.strftime(message.at, "%H:%M")}
                </time>
              </div>
              <%!-- Line breaks in a message are kept, so no whitespace around it. --%>
              <p
                phx-no-format
                class="mt-1 whitespace-pre-wrap text-[13px] leading-relaxed text-stone-300 [overflow-wrap:anywhere]"
              >{message.text}</p>
              <button
                :if={message.question}
                type="button"
                data-vote
                phx-click="vote"
                phx-value-id={message.id}
                aria-label={gettext("Vote for the question of %{name}", name: message.name)}
                aria-pressed={to_string(MapSet.member?(message.voters, @viewer))}
                class="mt-2 flex cursor-pointer items-center gap-1 rounded-md border border-stone-700 bg-stone-800 px-2 py-0.5 text-xs tabular-nums text-stone-400 hover:border-stone-600 hover:text-stone-200 aria-pressed:border-blue-500/60 aria-pressed:bg-blue-500/15 aria-pressed:text-blue-200"
              >
                <.icon name="hero-arrow-up" class="size-3" />
                <span>{MapSet.size(message.voters)}</span>
              </button>
            </article>
          </div>
        </div>

        <div class="border-t border-stone-800 p-3">
          <p :if={@error} id="watch-chat-error" role="alert" class="mb-2.5 text-xs text-red-300">
            {@error}
          </p>
          <%= cond do %>
            <% @connecting -> %>
              <div
                id="watch-chat-connecting"
                role="status"
                class="flex min-h-9 items-center justify-center text-xs text-stone-500 motion-safe:animate-pulse"
              >
                {gettext("Connecting…")}
              </div>
            <% not @open -> %>
              <div
                id="watch-chat-closed"
                role="status"
                class="flex min-h-9 items-center justify-center gap-2 text-center text-xs text-stone-500"
              >
                <.icon name="hero-lock-closed" class="size-4 flex-none" />
                {closed_note(@status)}
              </div>
            <% @name == "" -> %>
              <form id="watch-name-form" phx-submit="set_name" class="flex items-center gap-2">
                <label class="sr-only" for="watch-chat-name">{gettext("Your name")}</label>
                <input
                  id="watch-chat-name"
                  data-chat-name
                  name="name"
                  placeholder={gettext("Your name")}
                  maxlength={Chat.name_length()}
                  required
                  autocomplete="off"
                  class={input_class()}
                />
                <button
                  id="watch-name-submit"
                  type="submit"
                  aria-label={gettext("Join the chat")}
                  title={gettext("Join the chat")}
                  class={button_class()}
                >
                  <.icon name="hero-arrow-right" class="size-4" />
                </button>
              </form>
            <% true -> %>
              <form id="watch-message-form" phx-submit="send_message" phx-hook="chat_composer">
                <%!-- The fields belong to the browser: a new message from someone
                else must not reset what this viewer is typing. --%>
                <div id="watch-message-fields" phx-update="ignore">
                  <label class="sr-only" for="watch-message-text">{gettext("Your message")}</label>
                  <textarea
                    id="watch-message-text"
                    name="text"
                    placeholder={gettext("Message…")}
                    maxlength={Chat.text_length()}
                    rows="2"
                    required
                    class={[input_class(), "resize-none leading-relaxed"]}
                  ></textarea>
                  <div class="mt-2 flex items-center justify-between">
                    <label class="flex cursor-pointer items-center gap-1.5 text-xs text-stone-400">
                      <input
                        id="watch-message-question"
                        type="checkbox"
                        name="question"
                        value="true"
                        class="size-3 accent-blue-500"
                      />
                      {gettext("Ask as a question")}
                    </label>
                    <button
                      id="watch-message-submit"
                      type="submit"
                      aria-label={gettext("Send message")}
                      title={gettext("Send message")}
                      class={button_class()}
                    >
                      <.icon name="hero-arrow-up" class="size-4" />
                    </button>
                  </div>
                </div>
              </form>
          <% end %>
        </div>
      </aside>
    </main>
    """
  end

  defp input_class do
    "w-full min-w-0 rounded-lg border border-stone-700 bg-stone-800 px-3 py-2.5 text-[13px] text-stone-100 placeholder:text-stone-500 focus:border-stone-500 focus:outline-none"
  end

  defp button_class do
    "flex size-9 flex-none cursor-pointer items-center justify-center rounded-lg border border-stone-700 bg-stone-800 text-stone-200 hover:bg-stone-700 focus-visible:outline-2 focus-visible:outline-offset-2 focus-visible:outline-stone-400"
  end

  # The first paint, before the player script takes over the notice.
  defp notice(%{status: :idle}), do: gettext("This stream is offline.")
  defp notice(%{status: :ended, playable: false}), do: gettext("This stream has ended.")

  defp notice(%{status: status, playable: false}) when status in [:live, :disconnected],
    do: gettext("The broadcast is starting.")

  defp notice(_status), do: nil

  defp closed_note(%{status: :ended}), do: gettext("The chat closed when the broadcast ended.")
  defp closed_note(_status), do: gettext("The chat opens when the broadcast starts.")

  defp reload(socket) do
    %{stream: %{id: id, space: space}} = socket.assigns

    case LiveStreams.get(space, id) do
      %LiveStream{} = stream ->
        socket
        |> assign_stream(%{stream | space: space}, LiveStreams.public_status(stream))
        |> open_chat()

      # The stream was deleted: the address no longer leads anywhere.
      nil ->
        redirect(socket, to: ~p"/watch/#{socket.assigns.public_id}")
    end
  end

  defp assign_stream(socket, %LiveStream{} = stream, status) do
    title = if stream.name in [nil, ""], do: gettext("Live stream"), else: stream.name

    socket
    |> assign(:stream, stream)
    |> assign(:status, status)
    |> assign(:title, title)
    |> assign(:page_title, title)
  end

  defp open_chat(%{assigns: %{open: false, stream: stream}} = socket) do
    with true <- Chat.open?(stream),
         {:ok, %{messages: messages, status: status}} <- Chat.join(stream) do
      :ok = Chat.track(self(), stream.id, socket.assigns.viewer)

      socket
      |> assign(open: true, status: status, participants: Chat.participants(stream.id))
      |> stream(:messages, messages, reset: true, limit: -@history)
    else
      _closed -> socket
    end
  end

  defp open_chat(socket), do: socket

  defp close_chat(socket) do
    Chat.untrack(self(), socket.assigns.stream.id, socket.assigns.viewer)

    socket
    |> assign(open: false, participants: 0)
    |> stream(:messages, [], reset: true)
  end
end
