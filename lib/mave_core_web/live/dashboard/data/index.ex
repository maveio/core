defmodule MaveCoreWeb.Dashboard.Data.Index do
  @moduledoc false

  use MaveCoreWeb, :live_view
  import MaveCoreWeb.DashboardComponents, except: [icon: 1]

  alias MaveCore.Analytics
  alias MaveCore.Analytics.Range
  alias MaveCore.Analytics.RangeReport
  alias MaveCore.UsageLimits
  alias MaveCoreWeb.DashboardRoutes
  alias MaveCoreWeb.Formatter
  alias Phoenix.LiveView.AsyncResult

  def mount(_params, _session, socket) do
    {:ok,
     socket
     |> assign(:page_title, gettext("Data"))
     |> assign(:settings_open, false)
     |> assign(:show_all_devices, false)
     |> assign(:show_all_browsers, false)
     |> assign(:data_access_notice, nil)
     |> assign(:data_access_help, nil)
     |> assign(:range_form, to_form(default_range_params(), as: :range))
     |> assign(:range_error, nil)
     |> assign(:range_report, nil)
     |> assign(:selected_range, nil)
     |> assign(:range_loading, false)
     |> stream(:range_buckets, [])
     |> assign_async_defaults()}
  end

  def handle_params(params, _url, socket) do
    space_hash = socket.assigns.current_space.hash

    socket =
      case UsageLimits.can_view_space_data?(socket.assigns.current_space) do
        :ok ->
          socket
          |> assign(:data_access_notice, nil)
          |> assign(:data_access_help, nil)
          |> assign_async_defaults()
          |> start_async(:fetch_stats, fn -> Analytics.space_data(space_hash) end)
          |> load_range(params)

        {:error, reason} ->
          socket
          |> assign(:data_access_notice, data_access_notice(reason))
          |> assign(:data_access_help, data_access_help(reason))
          |> assign_empty_stats()
          |> clear_range()
      end

    {:noreply, socket}
  end

  def handle_async(:fetch_range, {:ok, {:ok, report}}, socket) do
    buckets = Enum.map(report.series, &Map.put(&1, :id, Date.to_iso8601(&1.date)))

    {:noreply,
     socket
     |> assign(:range_report, Map.delete(report, :series))
     |> assign(:range_loading, false)
     |> stream(:range_buckets, buckets, reset: true)}
  end

  def handle_async(:fetch_range, {:exit, {:shutdown, :cancel}}, socket), do: {:noreply, socket}

  def handle_async(:fetch_range, _failure, socket) do
    {:noreply,
     socket
     |> assign(:range_loading, false)
     |> assign(:range_error, gettext("Analytics are temporarily unavailable."))}
  end

  def handle_async(:fetch_stats, {:ok, {:ok, result}}, socket) do
    views_by_month = Enum.map(result.views_by_month, &Map.put(&1, :count, &1.views))
    max_views = Enum.max_by(views_by_month, & &1.count, fn -> %{count: 0} end).count
    max_month = max_views + max_views / 3

    {:noreply,
     socket
     |> assign(:views_today, AsyncResult.ok(socket.assigns.views_today, result.views.today))
     |> assign(
       :views_this_month,
       AsyncResult.ok(socket.assigns.views_this_month, result.views.month)
     )
     |> assign(
       :views_this_year,
       AsyncResult.ok(socket.assigns.views_this_year, result.views.year)
     )
     |> assign(:views_per_month, AsyncResult.ok(socket.assigns.views_per_month, views_by_month))
     |> assign(:devices, AsyncResult.ok(socket.assigns.devices, result.devices))
     |> assign(:browsers, AsyncResult.ok(socket.assigns.browsers, result.browsers))
     |> assign(:max_month, AsyncResult.ok(socket.assigns.max_month, max_month))
     |> assign(:show_all_devices, false)
     |> assign(:show_all_browsers, false)}
  end

  def handle_async(:fetch_stats, {:ok, {:error, _reason}}, socket),
    do: {:noreply, assign_failed(socket)}

  def handle_async(:fetch_stats, {:exit, _reason}, socket), do: {:noreply, assign_failed(socket)}

  def handle_event("select_range", %{"range" => params}, socket) do
    case Range.parse(params) do
      {:ok, %Range{} = range} ->
        path = DashboardRoutes.data_path(socket.assigns.current_space)
        {:noreply, push_patch(socket, to: path <> "?" <> URI.encode_query(Range.params(range)))}

      _ ->
        {:noreply,
         socket
         |> assign(:range_form, to_form(params, as: :range))
         |> assign(:range_error, Range.error_message())}
    end
  end

  def handle_event("reset_range", _params, socket) do
    {:noreply, push_patch(socket, to: DashboardRoutes.data_path(socket.assigns.current_space))}
  end

  def handle_event("toggle_show_all_devices", _, socket) do
    {:noreply, assign(socket, :show_all_devices, !socket.assigns.show_all_devices)}
  end

  def handle_event("toggle_show_all_browsers", _, socket) do
    {:noreply, assign(socket, :show_all_browsers, !socket.assigns.show_all_browsers)}
  end

  def render(assigns) do
    ~H"""
    <div class="h-full flex flex-col">
      <.title title={gettext("Data")}>
        <div
          :if={@data_access_notice}
          id="data-access-limit-notice"
          class="flex-none text-stone-400 text-opacity-70 text-sm cursor-default flex items-center"
        >
          <div>{@data_access_notice}</div>
          <.info_hover position="left">
            {@data_access_help}
          </.info_hover>
        </div>
      </.title>

      <div class="flex-1 overflow-y-auto">
        <div class="content opacity-100 scale-100">
          <div class="max-w-screen-xl px-16 mx-auto pt-8 pb-24">
            <section :if={!@data_access_notice} id="data-date-range" class="mb-8">
              <.form
                for={@range_form}
                id="analytics-range-form"
                phx-submit="select_range"
                class="flex flex-wrap items-end gap-4"
              >
                <.input field={@range_form[:from]} type="date" label={gettext("From (UTC)")} required />
                <.input field={@range_form[:to]} type="date" label={gettext("To (UTC)")} required />
                <.input
                  field={@range_form[:granularity]}
                  type="select"
                  label={gettext("Group by")}
                  options={[
                    {gettext("Day"), "day"},
                    {gettext("Week"), "week"},
                    {gettext("Month"), "month"}
                  ]}
                />
                <.dash_button id="analytics-range-submit" type="submit">{gettext("Apply dates")}</.dash_button>
                <.dash_button
                  :if={@selected_range}
                  id="analytics-range-reset"
                  type="button"
                  phx-click="reset_range"
                >{gettext("Reset")}</.dash_button>
              </.form>
              <p
                :if={@range_error}
                id="analytics-range-error"
                role="alert"
                class="mt-3 text-sm text-red-600"
              >
                {@range_error}
              </p>
              <p
                :if={@range_loading}
                id="analytics-range-loading"
                role="status"
                class="mt-4 text-sm text-stone-500"
              >
                {gettext("Loading selected period")}
              </p>
              <div :if={@range_report} class="mt-6">
                <div class="mb-4 flex flex-wrap items-center justify-between gap-4">
                  <p class="text-sm text-stone-500">
                    {@range_report.from} – {@range_report.to} (UTC)
                  </p>
                  <.link
                    id="analytics-csv-export"
                    href={export_path(@current_space, @selected_range)}
                    class="text-sm text-blue-600 hover:underline"
                  >
                    {gettext("Download CSV")}
                  </.link>
                </div>
                <div id="analytics-range-totals" class="grid grid-cols-1 gap-4 sm:grid-cols-3">
                  <.video_metric_card
                    label={gettext("Views in period")}
                    value={format_number(@range_report.totals.views)}
                  />
                  <.video_metric_card
                    label={gettext("Watch seconds")}
                    value={format_number(round(@range_report.totals.watch_seconds))}
                  />
                  <.video_metric_card
                    label={gettext("Average completion")}
                    value={completion_label(@range_report.totals.completion_rate)}
                  />
                </div>
                <div class="mt-4 max-h-72 overflow-auto rounded-lg border border-stone-100">
                  <table id="analytics-range-series" class="w-full text-left text-sm">
                    <thead>
                      <tr class="bg-stone-50 text-stone-500">
                        <th class="p-3">{gettext("Period (UTC)")}</th><th class="p-3">
                          {gettext("Views")}
                        </th><th class="p-3">{gettext("Watch seconds")}</th>
                      </tr>
                    </thead>
                    <tbody id="analytics-range-buckets" phx-update="stream">
                      <tr
                        :for={{id, bucket} <- @streams.range_buckets}
                        id={id}
                        class="border-t border-stone-100"
                      >
                        <td class="p-3">{bucket.date}</td><td class="p-3">
                          {format_number(bucket.views)}
                        </td><td class="p-3">{format_number(round(bucket.watch_seconds))}</td>
                      </tr>
                    </tbody>
                  </table>
                </div>
              </div>
            </section>

            <div class="mb-6">
              <.subtitle label={gettext("Numbers")} icon="hero-hashtag" />
            </div>

            <div class="grid grid-cols-3 gap-4 font-sans">
              <.video_metric_card
                label={gettext("Today")}
                value={metric_value(@views_today)}
                loading={@views_today.loading}
              />
              <.video_metric_card
                label={gettext("This month")}
                value={metric_value(@views_this_month)}
                loading={@views_this_month.loading}
              />
              <.video_metric_card
                label={gettext("This year")}
                value={metric_value(@views_this_year)}
                loading={@views_this_year.loading}
              />
            </div>

            <.divider />

            <div class="mb-6">
              <.subtitle label={gettext("History")} icon="hero-chart-bar" />
            </div>

            <.video_data_section>
              <div class="w-full h-56 flex flex-col">
                <.async_result :let={views_per_month} assign={@views_per_month}>
                  <:loading>
                    <div
                      id="data-history-loading"
                      class="flex min-h-0 flex-1 flex-col"
                      role="status"
                      aria-label={gettext("Loading history")}
                    >
                      <div class="flex-none flex items-center pt-4 text-center">
                        <%= for width <- [34, 42, 30, 38, 46, 32, 40, 28, 44, 34, 40, 30] do %>
                          <div class="w-full flex justify-center">
                            <div
                              class="data-loading-skeleton h-3 rounded-full"
                              style={"width: #{width}%"}
                              aria-hidden="true"
                            >
                            </div>
                          </div>
                        <% end %>
                      </div>
                      <div class="flex-grow flex items-end px-1 pb-5">
                        <%= for height <- [42, 67, 52, 78, 58, 86, 70, 47, 62, 38, 55, 31] do %>
                          <div class="w-full h-full flex items-end justify-center">
                            <div
                              class="data-loading-skeleton w-1 rounded-full"
                              style={"height: #{height}%"}
                              aria-hidden="true"
                            >
                            </div>
                          </div>
                        <% end %>
                      </div>
                      <span class="sr-only">{gettext("Loading data")}</span>
                    </div>
                  </:loading>

                  <div class="flex-none flex items-center pt-4 text-xs font-medium text-stone-300 text-center">
                    <%= for month <- views_per_month do %>
                      <div class="w-full">{format_number(month.count)}</div>
                    <% end %>
                  </div>
                  <div class="flex-grow flex items-center">
                    <%= for month <- views_per_month do %>
                      <div class="w-full flex justify-center">
                        <div class="h-32 w-1 bg-stone-50 flex items-end rounded-full overflow-hidden">
                          <div
                            :if={@max_month.ok? && @max_month.result}
                            class="w-full bg-blue-500"
                            style={"height: #{calc_height(month.count, @max_month.result)}%"}
                          >
                          </div>
                        </div>
                      </div>
                    <% end %>
                  </div>
                </.async_result>
                <div class="flex-none flex items-center py-1 text-xs font-medium text-stone-300 bg-stone-50 text-center">
                  <%= for month <- ~w(jan feb mar apr may jun jul aug sep oct nov dec)a do %>
                    <div class="w-full">{month}</div>
                  <% end %>
                </div>
              </div>
            </.video_data_section>

            <.divider />

            <div class="mb-6">
              <.subtitle label={gettext("Sources")} icon="hero-globe-alt" />
            </div>

            <div class="grid grid-cols-2 gap-4 mt-4">
              <.source_panel
                title={gettext("Device")}
                assign={@devices}
                rows={visible_devices(@devices, @show_all_devices)}
                toggle="toggle_show_all_devices"
                expanded={@show_all_devices}
                key_name={:device}
                empty_icon="device"
              />

              <.source_panel
                title={gettext("Browser")}
                assign={@browsers}
                rows={visible_browsers(@browsers, @show_all_browsers)}
                toggle="toggle_show_all_browsers"
                expanded={@show_all_browsers}
                key_name={:browser}
                empty_icon="browser"
              />
            </div>
          </div>
        </div>
      </div>

      <.footer />
    </div>
    """
  end

  attr :title, :string, required: true
  attr :assign, :any, required: true
  attr :rows, :list, required: true
  attr :toggle, :string, required: true
  attr :expanded, :boolean, required: true
  attr :key_name, :atom, required: true
  attr :empty_icon, :string, required: true

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

  defp load_range(socket, params) do
    socket = clear_range(socket)

    case Range.parse(params) do
      {:ok, nil} ->
        assign(socket, :range_form, to_form(default_range_params(), as: :range))

      {:ok, range} ->
        space_hash = socket.assigns.current_space.hash

        socket
        |> assign(:selected_range, range)
        |> assign(:range_form, to_form(Range.params(range), as: :range))
        |> assign(:range_loading, true)
        |> start_async(:fetch_range, fn -> RangeReport.fetch(space_hash, range) end)

      {:error, :invalid_range} ->
        socket
        |> assign(:range_form, to_form(Map.take(params, ~w(from to granularity)), as: :range))
        |> assign(:range_error, Range.error_message())
    end
  end

  defp clear_range(socket) do
    socket
    |> cancel_async(:fetch_range)
    |> assign(:selected_range, nil)
    |> assign(:range_report, nil)
    |> assign(:range_error, nil)
    |> assign(:range_loading, false)
    |> stream(:range_buckets, [], reset: true)
  end

  defp default_range_params do
    today = Date.utc_today()
    Range.params(%Range{from: Date.add(today, -29), to: today})
  end

  defp export_path(space, range) do
    DashboardRoutes.data_path(space) <> "/export.csv?" <> URI.encode_query(Range.params(range))
  end

  defp completion_label(nil), do: "—"
  defp completion_label(value), do: "#{round(value * 100)}%"

  defp metric_value(%AsyncResult{loading: true}), do: "..."

  defp metric_value(%AsyncResult{ok?: true, result: result}) when is_integer(result),
    do: format_number(result)

  defp metric_value(_), do: "0"

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
    |> assign(:max_month, AsyncResult.loading())
    |> assign(:devices, AsyncResult.loading())
    |> assign(:browsers, AsyncResult.loading())
    |> assign(:views_today, AsyncResult.loading())
    |> assign(:views_this_month, AsyncResult.loading())
    |> assign(:views_this_year, AsyncResult.loading())
    |> assign(:views_per_month, AsyncResult.loading())
  end

  defp assign_empty_stats(socket) do
    socket
    |> assign(:max_month, AsyncResult.ok(AsyncResult.loading(), 0))
    |> assign(:devices, AsyncResult.ok(AsyncResult.loading(), []))
    |> assign(:browsers, AsyncResult.ok(AsyncResult.loading(), []))
    |> assign(:views_today, AsyncResult.ok(AsyncResult.loading(), 0))
    |> assign(:views_this_month, AsyncResult.ok(AsyncResult.loading(), 0))
    |> assign(:views_this_year, AsyncResult.ok(AsyncResult.loading(), 0))
    |> assign(:views_per_month, AsyncResult.ok(AsyncResult.loading(), empty_months()))
    |> assign(:show_all_devices, false)
    |> assign(:show_all_browsers, false)
  end

  defp empty_months do
    Enum.map(1..12, fn _month -> %{count: 0, views: 0} end)
  end

  defp assign_failed(socket) do
    failed = AsyncResult.failed(AsyncResult.loading(), :analytics_unavailable)

    socket
    |> assign(:views_today, failed)
    |> assign(:views_this_month, failed)
    |> assign(:views_this_year, failed)
    |> assign(:views_per_month, failed)
    |> assign(:devices, failed)
    |> assign(:browsers, failed)
    |> assign(:max_month, failed)
  end

  defp calc_height(0, _max), do: 0
  defp calc_height(_count, 0), do: 0
  defp calc_height(count, max), do: 100 * count / max

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
