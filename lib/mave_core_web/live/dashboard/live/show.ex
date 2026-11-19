defmodule MaveCoreWeb.Dashboard.Live.Show do
  @moduledoc false

  use MaveCoreWeb, :live_view
  import MaveCoreWeb.DashboardComponents, except: [icon: 1]
  import MaveCoreWeb.Dashboard.Live.Components

  alias MaveCore.LiveStreams
  alias MaveCore.LiveStreams.{Config, LiveStream}
  alias MaveCoreWeb.DashboardRoutes

  def mount(%{"id" => id} = params, _session, socket) do
    space = socket.assigns.current_space
    scope = if params["space_id"] in [nil, ""], do: :unscoped, else: :scoped

    with true <- LiveStreams.available?(space),
         %LiveStream{} = stream <- LiveStreams.get(space, id) do
      if connected?(socket) do
        LiveStreams.subscribe(space.id)
        :timer.send_interval(1000, :tick)
      end

      {:ok,
       socket
       |> assign(:settings_open, false)
       |> assign(:route_scope, scope)
       |> assign(:key_revealed, false)
       |> assign(:confirm, nil)
       |> assign(:now, DateTime.utc_now())
       |> assign(:ingest_url, LiveStreams.ingest_url())
       |> assign_stream(stream)}
    else
      _ ->
        {:ok, push_navigate(socket, to: DashboardRoutes.live_streams_path(space, scope: scope))}
    end
  end

  def handle_params(_params, _url, socket), do: {:noreply, socket}

  def handle_info({:live_stream_updated, id}, %{assigns: %{stream: %{id: id}}} = socket),
    do: {:noreply, reload(socket)}

  def handle_info(:tick, socket) do
    socket = assign(socket, :now, DateTime.utc_now())

    # The reconnect window passes without an event of its own.
    if socket.assigns.stream.status in [:live, :disconnected],
      do: {:noreply, reload(socket)},
      else: {:noreply, socket}
  end

  def handle_info(_message, socket), do: {:noreply, socket}

  def handle_event("rename", %{"rename" => %{"name" => name}}, socket) do
    case LiveStreams.update(socket.assigns.stream, %{name: name}) do
      {:ok, stream} -> {:noreply, assign_stream(socket, stream)}
      {:error, _changeset} -> {:noreply, socket}
    end
  end

  def handle_event("toggle_key", _params, socket),
    do: {:noreply, update(socket, :key_revealed, &(!&1))}

  def handle_event("confirm", %{"action" => action}, socket)
      when action in ["delete", "reset_key"],
      do: {:noreply, assign(socket, :confirm, action)}

  def handle_event("cancel", _params, socket), do: {:noreply, assign(socket, :confirm, nil)}

  def handle_event("confirmed", _params, %{assigns: %{confirm: "reset_key"}} = socket) do
    {:ok, stream} = LiveStreams.reset_stream_key(socket.assigns.stream)

    {:noreply,
     socket
     |> assign(:confirm, nil)
     |> assign_stream(stream)
     |> put_flash(:info, gettext("Stream key replaced"))}
  end

  def handle_event("confirmed", _params, %{assigns: %{confirm: "delete"}} = socket) do
    {:ok, _stream} = LiveStreams.delete(socket.assigns.stream)

    {:noreply,
     push_navigate(socket,
       to:
         DashboardRoutes.live_streams_path(socket.assigns.current_space,
           scope: socket.assigns.route_scope
         )
     )}
  end

  def handle_event("confirmed", _params, socket), do: {:noreply, socket}

  def handle_event("end_broadcast", _params, socket) do
    LiveStreams.end_broadcast(socket.assigns.stream)
    {:noreply, reload(socket)}
  end

  def render(assigns) do
    ~H"""
    <div class="h-full flex flex-col">
      <.title
        title={stream_name(@stream)}
        contenteditable
        change="rename"
        form_id="live-stream-rename-form"
        contenteditable_id="live-stream-title"
      >
        <div class="flex items-center gap-4">
          <.status_badge id="live-stream-status" status={@stream.status} />
          <.dash_button
            id="live-stream-delete-button"
            icon="delete"
            type="button"
            phx-click="confirm"
            phx-value-action="delete"
          >
            {gettext("delete")}
          </.dash_button>
        </div>
      </.title>

      <div class="flex-1 overflow-y-auto">
        <div class="max-w-screen-xl mx-auto px-16 pt-10 pb-24 w-full">
          <div class="mb-6 text-sm">
            <.link
              id="live-stream-back"
              navigate={DashboardRoutes.live_streams_path(@current_space, scope: @route_scope)}
              class="text-stone-400 hover:text-blue-500"
            >
              ← {gettext("All live streams")}
            </.link>
          </div>

          <div class="grid grid-cols-1 gap-12 xl:grid-cols-[minmax(0,3fr)_minmax(0,2fr)]">
            <div>
              <div
                id="live-stream-preview"
                phx-update="ignore"
                class="aspect-video w-full overflow-hidden rounded-md bg-stone-950 ring-1 ring-stone-200"
              >
                <iframe
                  src={@player_url}
                  title={gettext("Live stream preview")}
                  class="h-full w-full border-0"
                  allow="autoplay; fullscreen"
                ></iframe>
              </div>

              <div id="live-stream-summary" class="mt-4 text-sm text-stone-500">
                {summary(@stream, @now, @recorded_seconds)}
              </div>
              <div :if={encoder_details(@stream)} class="mt-1 text-xs text-stone-400">
                {encoder_details(@stream)}
              </div>

              <div
                :if={@stream.last_error}
                id="live-stream-error"
                class="mt-4 rounded-md bg-red-50 px-3.5 py-2.5 text-sm text-red-700 ring-1 ring-inset ring-red-200"
              >
                {@stream.last_error}
              </div>

              <div :if={@stream.status == :disconnected} class="mt-4">
                <.dash_button id="live-stream-end-button" type="button" phx-click="end_broadcast">
                  {gettext("end broadcast now")}
                </.dash_button>
              </div>
            </div>

            <div>
              <.subtitle label={gettext("Encoder")} icon="cloud" />
              <p class="mt-3 text-sm text-stone-400">
                {gettext(
                  "In OBS, open Settings → Stream, choose Custom and paste these. Use H.264 video with a keyframe interval of 2 seconds."
                )}
              </p>
              <div class="mt-5">
                <.data_table>
                  <.address_field
                    id="live-stream-server"
                    label={gettext("Server")}
                    value={@ingest_url}
                  />
                  <div class="w-full p-3.5">
                    <div class="mb-1.5 flex items-center text-xs text-stone-400">
                      <div class="flex-grow">{gettext("Stream key")}</div>
                      <button
                        id="live-stream-reset-key-button"
                        type="button"
                        phx-click="confirm"
                        phx-value-action="reset_key"
                        class="cursor-pointer text-blue-500 hover:text-blue-600"
                      >
                        {gettext("replace key")}
                      </button>
                    </div>
                    <.secret_field
                      id="live-stream-key"
                      value={@stream.stream_key}
                      revealed={@key_revealed}
                      on_toggle={JS.push("toggle_key")}
                      secret_name={gettext("stream key")}
                    />
                  </div>
                </.data_table>
              </div>

              <div class="w-12 mt-10 mb-6 mx-auto border-t border-stone-100"></div>

              <.subtitle label={gettext("Playback")} icon="link" />
              <p class="mt-3 text-sm text-stone-400">
                {gettext(
                  "Viewers watch the broadcast at these addresses. After it ends they play the recording, until the next broadcast starts."
                )}
              </p>
              <div class="mt-5">
                <.data_table>
                  <.address_field
                    id="live-stream-watch"
                    label={gettext("Watch page with chat")}
                    value={@watch_url}
                  >
                    <:action>
                      <a
                        id="live-stream-watch-link"
                        href={@watch_url}
                        target="_blank"
                        rel="noopener"
                        class="text-blue-500 hover:text-blue-600"
                      >
                        {gettext("open")}
                      </a>
                    </:action>
                  </.address_field>
                  <.address_field
                    id="live-stream-embed"
                    label={gettext("Embed code")}
                    value={@embed_code}
                  />
                  <.address_field
                    id="live-stream-hls"
                    label={gettext("HLS playlist")}
                    value={@playback_url}
                  />
                </.data_table>
              </div>
            </div>
          </div>
        </div>
      </div>

      <.dialog
        id="live-stream-dialog"
        show={@confirm != nil}
        title={dialog_title(@confirm)}
        confirm_variant="danger"
        on_confirm={JS.push("confirmed")}
        on_cancel={JS.push("cancel")}
      >
        {dialog_text(@confirm)}
      </.dialog>

      <.footer />
    </div>
    """
  end

  defp reload(socket) do
    case LiveStreams.get(socket.assigns.current_space, socket.assigns.stream.id) do
      %LiveStream{} = stream ->
        assign_stream(socket, stream)

      nil ->
        push_navigate(socket,
          to:
            DashboardRoutes.live_streams_path(socket.assigns.current_space,
              scope: socket.assigns.route_scope
            )
        )
    end
  end

  defp assign_stream(socket, %LiveStream{} = stream) do
    space = socket.assigns.current_space

    recorded =
      if stream.status in [:ended, :disconnected],
        do: LiveStreams.recorded_seconds(stream),
        else: nil

    socket
    |> assign(:stream, stream)
    |> assign(:page_title, stream_name(stream))
    |> assign(:recorded_seconds, recorded)
    |> assign(:player_url, LiveStreams.player_url(space, stream))
    |> assign(:watch_url, LiveStreams.watch_url(space, stream))
    |> assign(:playback_url, LiveStreams.playback_url(space, stream))
    |> assign(:embed_code, LiveStreams.embed_code(space, stream))
  end

  defp summary(%LiveStream{status: :live, started_at: %DateTime{} = started}, now, _recorded),
    do: gettext("Live for %{duration}", duration: duration(DateTime.diff(now, started)))

  defp summary(%LiveStream{status: :disconnected, disconnected_at: %DateTime{} = at}, now, _) do
    left = max(Config.get(:reconnect_seconds) - DateTime.diff(now, at), 0)

    gettext(
      "The encoder disconnected. The broadcast continues if it reconnects within %{seconds} seconds.",
      seconds: left
    )
  end

  defp summary(%LiveStream{status: :ended}, _now, recorded) when is_number(recorded) do
    gettext("The broadcast ended. %{duration} recorded.", duration: duration(recorded))
  end

  defp summary(_stream, _now, _recorded),
    do: gettext("Waiting for the encoder. Start streaming to go live.")

  defp encoder_details(%LiveStream{ingest: %{} = ingest, status: status})
       when status in [:live, :disconnected] do
    [
      if(ingest["width"] && ingest["height"], do: "#{ingest["width"]}×#{ingest["height"]}"),
      if(ingest["framerate"], do: "#{format_rate(ingest["framerate"])} fps"),
      [ingest["video_codec"], ingest["audio_codec"]]
      |> Enum.reject(&is_nil/1)
      |> Enum.map_join(" / ", &String.upcase/1)
      |> case do
        "" -> nil
        codecs -> codecs
      end,
      if(ingest["video_bitrate"], do: "#{ingest["video_bitrate"]} kbps"),
      ingest["encoder"]
    ]
    |> Enum.reject(&is_nil/1)
    |> case do
      [] -> nil
      details -> Enum.join(details, " · ")
    end
  end

  defp encoder_details(_stream), do: nil

  defp format_rate(rate) when is_float(rate) do
    if rate == Float.round(rate), do: trunc(rate), else: Float.round(rate, 2)
  end

  defp format_rate(rate), do: rate

  defp dialog_title("reset_key"), do: gettext("Replace the stream key?")
  defp dialog_title(_action), do: gettext("Delete this live stream?")

  defp dialog_text("reset_key"),
    do: gettext("Encoders that use the current key can no longer start a broadcast.")

  defp dialog_text(_action),
    do: gettext("Its recording is removed and its playback addresses stop working.")
end
