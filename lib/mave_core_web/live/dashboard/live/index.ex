defmodule MaveCoreWeb.Dashboard.Live.Index do
  @moduledoc false

  use MaveCoreWeb, :live_view
  import MaveCoreWeb.DashboardComponents, except: [icon: 1]
  import MaveCoreWeb.Dashboard.Live.Components

  alias MaveCore.LiveStreams
  alias MaveCoreWeb.DashboardRoutes

  def mount(_params, _session, socket) do
    space = socket.assigns.current_space

    if LiveStreams.available?(space) do
      if connected?(socket), do: LiveStreams.subscribe(space.id)

      {:ok,
       socket
       |> assign(:page_title, gettext("Live"))
       |> assign(:settings_open, false)
       |> assign(:route_scope, :unscoped)
       |> assign(:live_streams, LiveStreams.list(space))}
    else
      {:ok, push_navigate(socket, to: DashboardRoutes.videos_path(space))}
    end
  end

  def handle_params(params, _url, socket) do
    scope = if params["space_id"] in [nil, ""], do: :unscoped, else: :scoped
    {:noreply, assign(socket, :route_scope, scope)}
  end

  def handle_info({:live_stream_updated, _id}, socket) do
    {:noreply, assign(socket, :live_streams, LiveStreams.list(socket.assigns.current_space))}
  end

  def handle_info(_message, socket), do: {:noreply, socket}

  def handle_event("create", _params, socket) do
    space = socket.assigns.current_space

    case LiveStreams.create(space) do
      {:ok, stream} ->
        {:noreply, push_navigate(socket, to: stream_path(socket, stream))}

      {:error, _reason} ->
        {:noreply, put_flash(socket, :error, gettext("Could not create a live stream"))}
    end
  end

  def render(assigns) do
    ~H"""
    <div class="h-full flex flex-col">
      <.title title={gettext("Live")}>
        <.dash_button
          :if={@live_streams != []}
          id="live-create-button"
          icon="create"
          type="button"
          phx-click="create"
        >
          {gettext("new stream")}
        </.dash_button>
      </.title>

      <div class="flex-1 overflow-y-auto">
        <div class="max-w-screen-xl mx-auto px-16 w-full">
          <div :if={@live_streams == []} id="live-empty-state" class="pt-16">
            <.empty_state title={gettext("Go live from OBS")}>
              {gettext(
                "Create a stream, paste its server and stream key into OBS or other streaming software, and start streaming."
              )}
              <:action>
                <.dash_button
                  id="live-empty-create-button"
                  icon="create"
                  type="button"
                  phx-click="create"
                >
                  {gettext("new stream")}
                </.dash_button>
              </:action>
            </.empty_state>
          </div>

          <div :if={@live_streams != []} id="live-streams" class="mt-8 mb-24">
            <.data_table>
              <.link
                :for={stream <- @live_streams}
                id={"live-stream-#{stream.id}"}
                navigate={stream_path(assigns, stream)}
                class="flex w-full items-center gap-4 border-b border-stone-100 p-3.5 text-sm last:border-none hover:bg-stone-50"
              >
                <div class="min-w-0 flex-1 truncate text-stone-600">{stream_name(stream)}</div>
                <div class="hidden w-56 flex-none truncate text-stone-400 sm:block">
                  {activity(stream)}
                </div>
                <div class="flex w-28 flex-none justify-end">
                  <.status_badge status={stream.status} />
                </div>
              </.link>
            </.data_table>
          </div>
        </div>
      </div>

      <.footer />
    </div>
    """
  end

  defp stream_path(%{assigns: assigns}, stream), do: stream_path(assigns, stream)

  defp stream_path(%{current_space: space, route_scope: scope}, stream),
    do: DashboardRoutes.live_stream_path(space, stream.id, scope: scope)

  defp activity(%{status: :live, started_at: %DateTime{} = at}),
    do: gettext("Started %{time}", time: Calendar.strftime(at, "%H:%M UTC"))

  defp activity(%{status: :ended, ended_at: %DateTime{} = at}),
    do: gettext("Last live %{date}", date: Calendar.strftime(at, "%-d %b %Y, %H:%M UTC"))

  defp activity(%{status: :idle}), do: gettext("Never streamed")
  defp activity(_stream), do: ""
end
