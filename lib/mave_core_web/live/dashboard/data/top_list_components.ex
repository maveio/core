defmodule MaveCoreWeb.Dashboard.Data.TopListComponents do
  @moduledoc false

  use MaveCoreWeb, :html
  import MaveCoreWeb.DashboardComponents, except: [icon: 1]

  alias MaveCoreWeb.DashboardRoutes
  alias MaveCoreWeb.Formatter
  alias Phoenix.LiveView.AsyncResult

  @sorts ~w(views watch_time completion)

  def sorts, do: @sorts
  def default_sort, do: "views"

  @doc "Sorts top list rows by `sort`, highest first."
  def sort(videos, "watch_time"), do: Enum.sort_by(videos, &{-&1.watch_ms, -&1.views})
  def sort(videos, "completion"), do: Enum.sort_by(videos, &{-&1.avg_completion, -&1.views})
  def sort(videos, _views), do: Enum.sort_by(videos, &(-&1.views))

  attr :top_videos, AsyncResult, required: true
  attr :current_space, :any, required: true
  attr :route_scope, :atom, required: true
  attr :sort, :string, required: true
  attr :sort_path, :any, required: true, doc: "function that builds the path for a sort"

  def top_list(assigns) do
    ~H"""
    <div class="mb-6">
      <.subtitle label={gettext("Top videos")} icon="hero-trophy" />
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
                <div class="data-loading-skeleton h-3.5 w-40 rounded-full" aria-hidden="true"></div>
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
        <div :if={top_videos != []} class="overflow-x-auto">
          <table id="data-top-list" class="w-full text-sm">
            <thead>
              <tr class="text-xs uppercase tracking-wide text-stone-400 border-b border-stone-100">
                <th class="w-10 px-3 py-2.5 text-left font-normal">#</th>
                <th class="px-3 py-2.5 text-left font-normal">{gettext("Video")}</th>
                <th :for={{sort, label} <- sort_columns()} class="px-3 py-2.5 text-right font-normal">
                  <.link
                    patch={@sort_path.(sort)}
                    data-sort={sort}
                    aria-sort={if sort == @sort, do: "descending"}
                    class={[
                      "whitespace-nowrap hover:text-stone-600",
                      sort == @sort && "text-stone-600"
                    ]}
                  >
                    {label}{if sort == @sort, do: " ▾"}
                  </.link>
                </th>
                <th class="px-3 py-2.5 text-left font-normal">{gettext("Trend")}</th>
              </tr>
            </thead>
            <tbody>
              <tr
                :for={{video, rank} <- Enum.with_index(top_videos, 1)}
                class="border-b border-stone-100 last:border-none hover:bg-stone-50"
              >
                <td class="px-3 py-2.5 text-stone-300 tabular-nums">{rank}</td>
                <td class="px-3 py-2.5 max-w-0 w-full">
                  <.link
                    navigate={
                      DashboardRoutes.video_path(@current_space, video.id, :all, scope: @route_scope)
                    }
                    class="block truncate text-stone-500 hover:text-stone-700"
                  >
                    {video.name}
                  </.link>
                </td>
                <td class="px-3 py-2.5 text-right text-stone-400 tabular-nums">
                  {format_number(video.views)}
                </td>
                <td class="px-3 py-2.5 text-right text-stone-400 tabular-nums whitespace-nowrap">
                  {format_watch_time(video.watch_ms)}
                </td>
                <td class="px-3 py-2.5 text-right text-stone-400 tabular-nums">
                  {round(video.avg_completion * 100)}%
                </td>
                <td class="px-3 py-2.5">
                  <.sparkline values={video.series} />
                </td>
              </tr>
            </tbody>
          </table>
        </div>
      </.video_data_section>
    </.async_result>
    """
  end

  attr :values, :list, required: true

  defp sparkline(assigns) do
    max = Enum.max(assigns.values, fn -> 0 end)
    step = 88 / max(length(assigns.values) - 1, 1)

    points =
      assigns.values
      |> Enum.with_index()
      |> Enum.map_join(" ", fn {value, index} ->
        y = if max > 0, do: 15 - 13 * value / max, else: 15
        "#{Float.round(index * step, 2)},#{Float.round(y, 2)}"
      end)

    assigns = assign(assigns, :points, points)

    ~H"""
    <svg viewBox="0 0 88 16" class="w-22 h-4 overflow-visible" aria-hidden="true">
      <polyline
        points={@points}
        fill="none"
        class="stroke-blue-500"
        stroke-width="1.5"
        stroke-linejoin="round"
      />
    </svg>
    """
  end

  defp sort_columns do
    [
      {"views", gettext("Views")},
      {"watch_time", gettext("Watch time")},
      {"completion", gettext("Completion")}
    ]
  end

  defp format_watch_time(ms) when ms >= 3_600_000,
    do: "#{format_number(Float.round(ms / 3_600_000, 1))} h"

  defp format_watch_time(ms), do: "#{format_number(round(ms / 60_000))} min"

  defp format_number(number), do: Formatter.format_number(number)
end
