defmodule MaveCoreWeb.Dashboard.Data.Index do
  @moduledoc false

  use MaveCoreWeb, :live_view
  import MaveCoreWeb.DashboardComponents, except: [icon: 1]

  @top_list_size 25
  # Deleted videos keep their analytics, so query extra rows to fill the list.
  @top_list_query_size 50

  alias MaveCore.Analytics.Overview
  alias MaveCore.Embeds
  alias MaveCore.UsageLimits
  alias MaveCoreWeb.Dashboard.Data.OverviewComponents
  alias MaveCoreWeb.Dashboard.Data.TopListComponents
  alias MaveCoreWeb.DashboardRoutes
  alias MaveCoreWeb.Formatter
  alias Phoenix.LiveView.AsyncResult

  def mount(_params, _session, socket) do
    {:ok,
     socket
     |> assign(:page_title, gettext("Data"))
     |> assign(:settings_open, false)
     |> assign(:route_scope, :unscoped)
     |> assign(:period, Overview.default_period())
     |> assign(:sort, TopListComponents.default_sort())
     |> assign(:expanded_sources, MapSet.new())
     |> assign(:data_access_notice, nil)
     |> assign(:data_access_help, nil)
     |> assign_async_defaults()}
  end

  def handle_params(params, _url, socket) do
    space = socket.assigns.current_space
    socket = assign(socket, period: period(params), sort: sort(params))

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
    %{period: period, sort: sort} = socket.assigns

    socket
    |> assign(:top_videos, AsyncResult.loading())
    |> start_async(:fetch_top_videos, fn -> fetch_top_videos(space, period, sort) end)
  end

  defp start_tab_fetch(socket, _overview, space) do
    period = socket.assigns.period

    socket
    |> assign_async_defaults()
    |> start_async(:fetch_overview, fn -> Overview.space_overview(space.hash, period) end)
  end

  defp fetch_top_videos(space, period, sort) do
    with {:ok, rows} <- Overview.top_videos(space.hash, period, @top_list_query_size) do
      videos = Embeds.dashboard_videos_by_hash(space, Enum.map(rows, & &1.embed_hash))

      top_videos =
        for %{embed_hash: hash} = row <- rows,
            Map.has_key?(videos, hash),
            do: Map.merge(row, videos[hash])

      {:ok, top_videos |> Enum.take(@top_list_size) |> TopListComponents.sort(sort)}
    end
  end

  def handle_async(:fetch_overview, {:ok, {:ok, overview}}, socket) do
    {:noreply,
     socket
     |> assign(:overview, AsyncResult.ok(socket.assigns.overview, overview))
     |> assign(:expanded_sources, MapSet.new())}
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
    {:noreply, assign(socket, :top_videos, AsyncResult.ok(socket.assigns.top_videos, top_videos))}
  end

  def handle_async(:fetch_top_videos, _result, socket) do
    {:noreply,
     assign(
       socket,
       :top_videos,
       AsyncResult.failed(socket.assigns.top_videos, :analytics_unavailable)
     )}
  end

  def handle_event("toggle_source", %{"source" => source}, socket)
      when source in ["device", "browser", "os", "website"] do
    expanded = socket.assigns.expanded_sources

    expanded =
      if MapSet.member?(expanded, source),
        do: MapSet.delete(expanded, source),
        else: MapSet.put(expanded, source)

    {:noreply, assign(socket, :expanded_sources, expanded)}
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
          <OverviewComponents.period_switch period={@period} path={&period_path(assigns, &1)} />
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
            <%= if @live_action == :top_list do %>
              <TopListComponents.top_list
                top_videos={@top_videos}
                current_space={@current_space}
                route_scope={@route_scope}
                sort={@sort}
                sort_path={&top_list_path(assigns, @period, &1)}
              />
            <% else %>
              <OverviewComponents.kpis overview={@overview} period={@period} />

              <.divider />

              <div class="mb-6">
                <.subtitle label={gettext("History")} icon="hero-chart-bar" />
              </div>

              <OverviewComponents.trend overview={@overview} />

              <.divider />

              <div class="mb-6">
                <.subtitle label={gettext("Engagement")} icon="hero-play-circle" />
              </div>

              <div class="grid grid-cols-1 xl:grid-cols-2 gap-4">
                <OverviewComponents.reach overview={@overview} />
                <OverviewComponents.hours overview={@overview} />
              </div>

              <.divider />

              <div class="mb-6">
                <.subtitle label={gettext("Sources")} icon="hero-globe-alt" />
              </div>

              <div class="grid grid-cols-2 gap-4 mt-4">
                <.source_panel
                  title={gettext("Device")}
                  assign={overview_field(@overview, :devices)}
                  expanded={MapSet.member?(@expanded_sources, "device")}
                  key_name={:device}
                  empty_icon="device"
                />

                <.source_panel
                  title={gettext("Browser")}
                  assign={overview_field(@overview, :browsers)}
                  expanded={MapSet.member?(@expanded_sources, "browser")}
                  key_name={:browser}
                  empty_icon="browser"
                />

                <.source_panel
                  title={gettext("Operating system")}
                  assign={overview_field(@overview, :operating_systems)}
                  expanded={MapSet.member?(@expanded_sources, "os")}
                  key_name={:os}
                  empty_icon="os"
                  capitalize={false}
                />

                <.source_panel
                  title={gettext("Websites")}
                  assign={overview_field(@overview, :websites)}
                  expanded={MapSet.member?(@expanded_sources, "website")}
                  key_name={:website}
                  empty_icon="website"
                  capitalize={false}
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

  attr :title, :string, required: true
  attr :assign, :any, required: true
  attr :expanded, :boolean, required: true
  attr :key_name, :atom, required: true
  attr :empty_icon, :string, required: true
  attr :capitalize, :boolean, default: true

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
          <%= for row <- visible_rows(rows, @key_name, @expanded) do %>
            <div class="flex gap-3 px-3 py-2.5 border-b border-stone-100 last:border-none hover:bg-stone-50 active:bg-blue-50">
              <div class="flex-grow min-w-0 truncate text-sm text-stone-400">
                {source_label(Map.fetch!(row, @key_name), @capitalize)}
              </div>
              <div class="text-sm text-stone-400 tabular-nums">{format_number(row.views)}</div>
            </div>
          <% end %>
          <%= if length(visible_rows(rows, @key_name, false)) < length(visible_rows(rows, @key_name, true)) do %>
            <button
              type="button"
              class="w-full px-3 py-2.5 bg-stone-50 border-t border-stone-100 flex justify-center cursor-pointer hover:bg-stone-100"
              phx-click="toggle_source"
              phx-value-source={@empty_icon}
            >
              <span class="text-sm text-stone-500 text-opacity-60">
                {if @expanded, do: gettext("Show less"), else: gettext("Show more")}
              </span>
            </button>
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
    if period in Overview.periods(), do: period, else: Overview.default_period()
  end

  defp period(_params), do: Overview.default_period()

  defp period_path(%{live_action: :top_list} = assigns, period),
    do: top_list_path(assigns, period, assigns.sort)

  defp period_path(assigns, period) do
    DashboardRoutes.data_path(assigns.current_space,
      scope: assigns.route_scope,
      period: period_param(period)
    )
  end

  defp top_list_path(assigns, period, sort) do
    DashboardRoutes.data_top_list_path(assigns.current_space,
      scope: assigns.route_scope,
      period: period_param(period),
      sort: if(sort != TopListComponents.default_sort(), do: sort)
    )
  end

  defp sort(%{"sort" => sort}) do
    if sort in TopListComponents.sorts(), do: sort, else: TopListComponents.default_sort()
  end

  defp sort(_params), do: TopListComponents.default_sort()

  # Keeps URLs for the default period free of a query string.
  defp period_param(period) do
    if period == Overview.default_period(), do: nil, else: period
  end

  defp overview_field(%AsyncResult{ok?: true, result: overview} = result, field),
    do: %{result | result: Map.fetch!(overview, field)}

  defp overview_field(%AsyncResult{} = result, _field), do: result

  defp format_number(number), do: Formatter.format_number(number)

  defp visible_rows(rows, :browser, expanded?) do
    rows
    |> Enum.reject(&(&1.browser in ["ie", "firefox", "brave", "opera"] and &1.views == 0))
    |> visible_rows(nil, expanded?)
  end

  defp visible_rows(rows, _key, true), do: rows
  defp visible_rows(rows, _key, false), do: Enum.take(rows, 5)

  defp source_label(value, true), do: value |> to_string() |> String.capitalize()
  defp source_label(value, false), do: to_string(value)

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
    |> assign(:expanded_sources, MapSet.new())
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
