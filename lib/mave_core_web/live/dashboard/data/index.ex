defmodule MaveCoreWeb.Dashboard.Data.Index do
  @moduledoc false

  use MaveCoreWeb, :live_view
  import MaveCoreWeb.DashboardComponents, except: [icon: 1]

  @top_list_size 25
  # Deleted videos keep their analytics, so query extra rows to fill the list.
  @top_list_query_size 50

  alias MaveCore.Analytics
  alias MaveCore.Analytics.Overview
  alias MaveCore.Embeds
  alias MaveCore.UsageLimits
  alias MaveCoreWeb.Dashboard.Data.OverviewComponents
  alias MaveCoreWeb.DashboardRoutes
  alias MaveCoreWeb.Formatter
  alias Phoenix.LiveView.AsyncResult

  def mount(_params, _session, socket) do
    {:ok,
     socket
     |> assign(:analytics_preparing, false)
     |> assign(:page_title, gettext("Data"))
     |> assign(:settings_open, false)
     |> assign(:route_scope, :unscoped)
     |> assign(:period, Overview.default_period())
     |> assign(:show_all_devices, false)
     |> assign(:show_all_browsers, false)
     |> assign(:data_access_notice, nil)
     |> assign(:data_access_help, nil)
     |> assign_async_defaults()}
  end

  def handle_params(params, _url, socket) do
    space = socket.assigns.current_space
    socket = assign(socket, :period, period(params))

    socket =
      case UsageLimits.can_view_space_data?(space) do
        :ok ->
          socket
          |> assign(:data_access_notice, nil)
          |> assign(:data_access_help, nil)
          |> start_tab_fetch(socket.assigns.live_action, space)

        {:error, reason} ->
          socket
          |> assign(:data_access_notice, data_access_notice(reason))
          |> assign(:data_access_help, data_access_help(reason))
          |> assign_empty_stats()
      end

    {:noreply, assign(socket, :route_scope, route_scope(params))}
  end

  defp start_tab_fetch(socket, :top_list, space) do
    socket
    |> assign(:top_videos, AsyncResult.loading())
    |> start_async(:fetch_top_videos, fn -> fetch_top_videos(space) end)
  end

  defp start_tab_fetch(socket, _overview, space) do
    period = socket.assigns.period

    socket
    |> assign_async_defaults()
    |> start_async(:fetch_overview, fn -> Overview.space_overview(space.hash, period) end)
  end

  defp fetch_top_videos(space) do
    with {:ok, rows} <- Analytics.space_top_videos(space.hash, @top_list_query_size) do
      videos = Embeds.dashboard_videos_by_hash(space, Enum.map(rows, & &1.embed_hash))

      top_videos =
        for %{embed_hash: hash, views: views} <- rows,
            Map.has_key?(videos, hash),
            do: Map.put(videos[hash], :views, views)

      {:ok, Enum.take(top_videos, @top_list_size)}
    end
  end

  def handle_async(:fetch_overview, {:ok, {:ok, overview}}, socket) do
    socket = assign(socket, :analytics_preparing, false)

    {:noreply,
     socket
     |> assign(:overview, AsyncResult.ok(socket.assigns.overview, overview))
     |> assign(:show_all_devices, false)
     |> assign(:show_all_browsers, false)}
  end

  def handle_async(:fetch_overview, {:ok, {:error, :preparing}}, socket) do
    Process.send_after(self(), {:refresh_analytics, socket.assigns.current_space.hash}, 5_000)
    {:noreply, assign(socket, :analytics_preparing, true)}
  end

  def handle_async(:fetch_overview, _result, socket) do
    {:noreply,
     assign(
       socket,
       :overview,
       AsyncResult.failed(socket.assigns.overview, :analytics_unavailable)
     )}
  end

  def handle_async(:fetch_top_videos, {:ok, {:ok, top_videos}}, socket) do
    {:noreply,
     socket
     |> assign(:analytics_preparing, false)
     |> assign(:top_videos, AsyncResult.ok(socket.assigns.top_videos, top_videos))}
  end

  def handle_async(:fetch_top_videos, {:ok, {:error, :preparing}}, socket) do
    Process.send_after(self(), {:refresh_analytics, socket.assigns.current_space.hash}, 5_000)
    {:noreply, assign(socket, :analytics_preparing, true)}
  end

  def handle_async(:fetch_top_videos, _result, socket) do
    {:noreply,
     assign(
       socket,
       :top_videos,
       AsyncResult.failed(socket.assigns.top_videos, :analytics_unavailable)
     )}
  end

  def handle_info({:refresh_analytics, space_hash}, socket) do
    if socket.assigns.current_space.hash == space_hash and socket.assigns.analytics_preparing do
      {:noreply,
       start_tab_fetch(socket, socket.assigns.live_action, socket.assigns.current_space)}
    else
      {:noreply, socket}
    end
  end

  def handle_info(_message, socket), do: {:noreply, socket}

  def handle_event("toggle_show_all_devices", _, socket) do
    {:noreply, assign(socket, :show_all_devices, !socket.assigns.show_all_devices)}
  end

  def handle_event("toggle_show_all_browsers", _, socket) do
    {:noreply, assign(socket, :show_all_browsers, !socket.assigns.show_all_browsers)}
  end

  def render(assigns) do
    ~H"""
    <div class="h-full flex flex-col">
      <div class="h-16 flex-none"></div>
      <div class="flex-none">
        <.menubar>
          <.menubar_item
            icon="hero-chart-bar-mini"
            path={
              DashboardRoutes.data_path(@current_space,
                scope: @route_scope,
                period: period_param(@period)
              )
            }
            active={@live_action != :top_list}
          >
            {gettext("Overview")}
          </.menubar_item>
          <.menubar_item
            icon="hero-trophy-mini"
            path={
              DashboardRoutes.data_top_list_path(@current_space,
                scope: @route_scope,
                period: period_param(@period)
              )
            }
            active={@live_action == :top_list}
          >
            {gettext("Top list")}
          </.menubar_item>
          <div class="flex-grow"></div>
          <OverviewComponents.period_switch
            :if={@live_action != :top_list}
            period={@period}
            path={&period_path(assigns, &1)}
          />
          <div
            :if={@data_access_notice}
            id="data-access-limit-notice"
            class="flex-none ml-4 text-stone-400 text-opacity-70 text-sm cursor-default flex items-center"
          >
            <div>{@data_access_notice}</div>
            <.info_hover position="left">
              {@data_access_help}
            </.info_hover>
          </div>
        </.menubar>
      </div>

      <div class="flex-1 overflow-y-auto">
        <div class="content opacity-100 scale-100">
          <div class="max-w-screen-xl px-16 mx-auto pt-10 pb-24">
            <p
              :if={@analytics_preparing}
              id="analytics-preparing"
              role="status"
              class="mb-6 text-sm text-stone-500"
            >
              {gettext("Analytics are being prepared. Please check back shortly.")}
            </p>
            <%= if @live_action == :top_list do %>
              <.top_list
                top_videos={@top_videos}
                current_space={@current_space}
                route_scope={@route_scope}
              />
            <% else %>
              <OverviewComponents.kpis overview={@overview} period={@period} />

              <.divider />

              <div class="mb-6">
                <.subtitle label={gettext("History")} icon="hero-chart-bar" />
              </div>

              <OverviewComponents.trend overview={@overview} period={@period} />

              <.divider />

              <div class="mb-6">
                <.subtitle label={gettext("Sources")} icon="hero-globe-alt" />
              </div>

              <div class="grid grid-cols-2 gap-4 mt-4">
                <.source_panel
                  title={gettext("Device")}
                  assign={overview_field(@overview, :devices)}
                  rows={visible_devices(overview_field(@overview, :devices), @show_all_devices)}
                  toggle="toggle_show_all_devices"
                  expanded={@show_all_devices}
                  key_name={:device}
                  empty_icon="device"
                />

                <.source_panel
                  title={gettext("Browser")}
                  assign={overview_field(@overview, :browsers)}
                  rows={visible_browsers(overview_field(@overview, :browsers), @show_all_browsers)}
                  toggle="toggle_show_all_browsers"
                  expanded={@show_all_browsers}
                  key_name={:browser}
                  empty_icon="browser"
                />
              </div>
            <% end %>
          </div>
        </div>
      </div>

      <.footer />
    </div>
    """
  end

  attr(:top_videos, AsyncResult, required: true)
  attr(:current_space, :any, required: true)
  attr(:route_scope, :atom, required: true)

  defp top_list(assigns) do
    ~H"""
    <div class="mb-6">
      <.subtitle label={gettext("Most viewed this year")} icon="hero-trophy" />
    </div>

    <.async_result :let={top_videos} assign={@top_videos}>
      <:loading>
        <div id="data-top-list-loading" role="status" aria-label={gettext("Loading top list")}>
          <.video_data_section>
            <%= for width <- [46, 38, 52, 30, 42, 35, 48, 33] do %>
              <div class="flex items-center gap-4 px-3 py-2.5 border-b border-stone-100 last:border-none">
                <div class="data-loading-skeleton h-3.5 w-4 flex-none rounded-full" aria-hidden="true">
                </div>
                <div class="flex-grow">
                  <div
                    class="data-loading-skeleton h-3.5 rounded-full"
                    style={"width: #{width}%"}
                    aria-hidden="true"
                  >
                  </div>
                </div>
                <div class="data-loading-skeleton h-3.5 w-10 rounded-full" aria-hidden="true"></div>
              </div>
            <% end %>
            <span class="sr-only">{gettext("Loading data")}</span>
          </.video_data_section>
        </div>
      </:loading>

      <:failed>
        <.video_data_section>
          <div class="py-8 text-center text-sm font-medium text-stone-400">
            {gettext("Data is unavailable")}
          </div>
        </.video_data_section>
      </:failed>

      <.video_data_section>
        <div
          :if={top_videos == []}
          class="flex flex-col items-center justify-center py-8 text-stone-400"
        >
          <.icon name="hero-trophy" class="h-6 w-6 mb-2 opacity-50" />
          <div class="text-sm font-medium">{gettext("No data yet")}</div>
        </div>
        <div id="data-top-list">
          <.link
            :for={{video, rank} <- Enum.with_index(top_videos, 1)}
            navigate={DashboardRoutes.video_path(@current_space, video.id, :all, scope: @route_scope)}
            class="flex items-center gap-4 px-3 py-2.5 border-b border-stone-100 last:border-none hover:bg-stone-50 active:bg-blue-50"
          >
            <div class="w-6 flex-none text-sm text-stone-300 tabular-nums">{rank}</div>
            <div class="flex-grow min-w-0 truncate text-sm text-stone-500">{video.name}</div>
            <div class="flex-none text-sm text-stone-400 tabular-nums">
              {format_number(video.views)}
            </div>
          </.link>
        </div>
      </.video_data_section>
    </.async_result>
    """
  end

  attr(:title, :string, required: true)
  attr(:assign, :any, required: true)
  attr(:rows, :list, required: true)
  attr(:toggle, :string, required: true)
  attr(:expanded, :boolean, required: true)
  attr(:key_name, :atom, required: true)
  attr(:empty_icon, :string, required: true)

  defp source_panel(assigns) do
    ~H"""
    <.async_result :let={rows} assign={@assign}>
      <:loading>
        <div
          id={"data-#{@empty_icon}-sources-loading"}
          role="status"
          aria-label={gettext("Loading sources")}
        >
          <.video_data_section label={@title}>
            <%= for width <- [32, 45, 38, 52, 35] do %>
              <div class="flex items-center gap-3 px-3 py-2.5 border-b border-stone-100 last:border-none">
                <div
                  class="data-loading-skeleton size-4 flex-none rounded"
                  aria-hidden="true"
                >
                </div>
                <div class="flex-grow">
                  <div
                    class="data-loading-skeleton h-3.5 rounded-full"
                    style={"width: #{width}%"}
                    aria-hidden="true"
                  >
                  </div>
                </div>
                <div
                  class="data-loading-skeleton h-3.5 w-8 rounded-full"
                  aria-hidden="true"
                >
                </div>
              </div>
            <% end %>
            <span class="sr-only">{gettext("Loading data")}</span>
          </.video_data_section>
        </div>
      </:loading>

      <.video_data_section label={@title}>
        <%= if rows == [] do %>
          <div class="flex flex-col items-center justify-center py-8 text-stone-400">
            <%= if @empty_icon == "device" do %>
              <svg
                xmlns="http://www.w3.org/2000/svg"
                class="h-6 w-6 mb-2 opacity-50"
                fill="none"
                viewBox="0 0 24 24"
                stroke="currentColor"
              >
                <path
                  stroke-linecap="round"
                  stroke-linejoin="round"
                  stroke-width="1.5"
                  d="M9.75 17L9 20l-1 1h8l-1-1-.75-3M3 13h18M5 17h14a2 2 0 002-2V5a2 2 0 00-2-2H5a2 2 0 00-2 2v10a2 2 0 002 2z"
                />
              </svg>
            <% else %>
              <svg
                xmlns="http://www.w3.org/2000/svg"
                class="h-6 w-6 mb-2 opacity-50"
                fill="none"
                viewBox="0 0 24 24"
                stroke="currentColor"
              >
                <path
                  stroke-linecap="round"
                  stroke-linejoin="round"
                  stroke-width="1.5"
                  d="M21 12a9 9 0 01-9 9m9-9a9 9 0 00-9-9m9 9H3m9 9a9 9 0 01-9-9m9 9c1.657 0 3-9 3-9s-1.343-9-3-9m0 18c-1.657 0-3-9-3-9s1.343-9 3-9m-9 9a9 9 0 019-9"
                />
              </svg>
            <% end %>
            <div class="text-sm font-medium">{gettext("No data yet")}</div>
          </div>
        <% else %>
          <%= for row <- @rows do %>
            <div class="flex px-3 py-2.5 border-b border-stone-100 last:border-none hover:bg-stone-50 active:bg-blue-50">
              <div class="flex-grow text-sm text-stone-400">
                {row |> Map.fetch!(@key_name) |> to_string() |> String.capitalize()}
              </div>
              <div class="text-sm text-stone-400">{format_number(row.views)}</div>
            </div>
          <% end %>
          <%= if length(rows) < length(@assign.result || []) do %>
            <div
              class="px-3 py-2.5 bg-stone-50 border-t border-stone-100 flex justify-center cursor-pointer hover:bg-stone-100"
              phx-click={@toggle}
            >
              <span class="text-sm text-stone-500 text-opacity-60">
                {if @expanded, do: gettext("Show less"), else: gettext("Show more")}
              </span>
            </div>
          <% end %>
        <% end %>
      </.video_data_section>
    </.async_result>
    """
  end

  defp route_scope(%{"space_id" => space_id}) when is_binary(space_id) and space_id != "",
    do: :scoped

  defp route_scope(_params), do: :unscoped

  defp period(%{"period" => period}) do
    period =
      Map.get(
        %{"24h" => "today", "7d" => "week", "30d" => "month", "12m" => "year"},
        period,
        period
      )

    if period in Overview.periods(), do: period, else: Overview.default_period()
  end

  defp period(_params), do: Overview.default_period()

  defp period_path(assigns, period) do
    DashboardRoutes.data_path(assigns.current_space,
      scope: assigns.route_scope,
      period: period_param(period)
    )
  end

  # Keeps URLs for the default period free of a query string.
  defp period_param(period) do
    if period == Overview.default_period(), do: nil, else: period
  end

  defp overview_field(%AsyncResult{ok?: true, result: overview} = result, field),
    do: %{result | result: Map.fetch!(overview, field)}

  defp overview_field(%AsyncResult{} = result, _field), do: result

  defp format_number(number), do: Formatter.format_number(number)

  defp visible_devices(%AsyncResult{ok?: true, result: devices}, true), do: devices
  defp visible_devices(%AsyncResult{ok?: true, result: devices}, false), do: Enum.take(devices, 5)
  defp visible_devices(_, _), do: []

  defp visible_browsers(%AsyncResult{ok?: true, result: browsers}, expanded?) do
    filtered =
      Enum.filter(browsers, fn %{browser: type, views: count} ->
        not (type in ["ie", "firefox", "brave", "opera"] and count == 0)
      end)

    if expanded?, do: filtered, else: Enum.take(filtered, 5)
  end

  defp visible_browsers(_, _), do: []

  defp assign_async_defaults(socket) do
    socket
    |> assign(:top_videos, AsyncResult.loading())
    |> assign(:overview, AsyncResult.loading())
  end

  defp assign_empty_stats(socket) do
    socket
    |> assign(
      :overview,
      AsyncResult.ok(AsyncResult.loading(), Overview.empty(socket.assigns.period))
    )
    |> assign(:top_videos, AsyncResult.ok(AsyncResult.loading(), []))
    |> assign(:show_all_devices, false)
    |> assign(:show_all_browsers, false)
  end

  defp data_access_notice(reason) do
    :view_space_data
    |> UsageLimits.restriction_copy(reason)
    |> Map.get(:notice, gettext("Data is unavailable"))
  end

  defp data_access_help(reason) do
    :view_space_data
    |> UsageLimits.restriction_copy(reason)
    |> Map.get(:help, gettext("This space cannot view statistics right now."))
  end
end
