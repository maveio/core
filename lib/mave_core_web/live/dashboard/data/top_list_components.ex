defmodule MaveCoreWeb.Dashboard.Data.TopListComponents do
  @moduledoc false

  use MaveCoreWeb, :html
  import MaveCoreWeb.DashboardComponents, except: [icon: 1]

  alias MaveCoreWeb.DashboardRoutes
  alias MaveCoreWeb.Formatter
  alias Phoenix.LiveView.AsyncResult

  def sorts, do: ~w(views watch_time completion)
  def default_sort, do: "default"

  attr :sort, :string, required: true
  attr :direction, :string, values: ~w(asc desc), required: true
  attr :sort_path, :any, required: true
  attr :top_videos, AsyncResult, required: true
  attr :current_space, :any, required: true
  attr :route_scope, :atom, required: true

  def top_list(assigns) do
    ~H"""
    <div class="mb-6">
      <.subtitle label={gettext("Top videos")} icon="hero-trophy" />
    </div>

    <div id="data-top-list" class="overflow-x-auto">
      <div class="min-w-[34rem]">
        <.data_table variant={:compact}>
          <:header>
            <.data_table_header_cell variant={:compact} width="2.5rem" class="flex-none">
              #
            </.data_table_header_cell>
            <.data_table_header_cell variant={:compact} class="min-w-0 flex-1">
              {gettext("Video")}
            </.data_table_header_cell>
            <.data_table_header_cell
              :for={{sort, label, width} <- sort_columns()}
              variant={:compact}
              width={width}
              align="right"
              class="flex-none whitespace-nowrap"
            >
              <.link
                patch={sort_path(@sort_path, @sort, @direction, sort)}
                data-sort={sort}
                aria-current={if sort == @sort, do: "true"}
                class={["hover:text-stone-600", sort == @sort && "text-stone-600"]}
              >
                {label}<span class="inline-block w-3 text-right" aria-hidden="true">{if sort == @sort,
                  do: if(@direction == "asc", do: "↑", else: "↓"),
                  else: ""}</span>
              </.link>
            </.data_table_header_cell>
          </:header>

          <.async_result :let={top_videos} assign={@top_videos}>
            <:loading>
              <div id="data-top-list-loading" role="status" aria-label={gettext("Loading top list")}>
                <.data_table_row :for={width <- [46, 38, 52, 30, 42, 35, 48, 33]} variant={:compact}>
                  <.data_table_cell variant={:compact} width="2.5rem" class="flex-none">
                    <div class="data-loading-skeleton h-3.5 w-4 rounded-full" aria-hidden="true">
                    </div>
                  </.data_table_cell>
                  <.data_table_cell variant={:compact} class="min-w-0 flex-1">
                    <div
                      class="data-loading-skeleton h-3.5 rounded-full"
                      style={"width: #{width}%"}
                      aria-hidden="true"
                    >
                    </div>
                  </.data_table_cell>
                  <.data_table_cell
                    :for={width <- ["6rem", "7rem", "7rem"]}
                    variant={:compact}
                    width={width}
                    class="flex-none justify-end"
                  >
                    <div class="data-loading-skeleton h-3.5 w-10 rounded-full" aria-hidden="true">
                    </div>
                  </.data_table_cell>
                </.data_table_row>
                <span class="sr-only">{gettext("Loading data")}</span>
              </div>
            </:loading>

            <:failed>
              <div class="py-8 text-center text-sm font-medium text-stone-400">
                {gettext("Data is unavailable")}
              </div>
            </:failed>

            <div
              :if={top_videos == []}
              class="flex flex-col items-center justify-center py-8 text-stone-400"
            >
              <.icon name="hero-trophy" class="h-6 w-6 mb-2 opacity-50" />
              <div class="text-sm font-medium">{gettext("No data yet")}</div>
            </div>

            <.data_table_row
              :for={{video, rank} <- Enum.with_index(sort_rows(top_videos, @sort, @direction), 1)}
              variant={:compact}
              id={"data-top-video-#{video.id}"}
            >
              <.data_table_cell variant={:compact} width="2.5rem" class="flex-none tabular-nums">
                {rank}
              </.data_table_cell>
              <.data_table_cell variant={:compact} class="min-w-0 flex-1" truncate>
                <.link
                  navigate={
                    DashboardRoutes.video_path(@current_space, video.id, :all, scope: @route_scope)
                  }
                  class="block w-full truncate text-stone-400 hover:text-stone-600"
                >
                  {video.name}
                </.link>
              </.data_table_cell>
              <.data_table_cell
                variant={:compact}
                width="6rem"
                class="flex-none justify-end tabular-nums whitespace-nowrap"
              >
                {format_number(video.views)}
              </.data_table_cell>
              <.data_table_cell
                variant={:compact}
                width="7rem"
                class="flex-none justify-end tabular-nums whitespace-nowrap"
              >
                {format_watch_time(video.watch_ms)}
              </.data_table_cell>
              <.data_table_cell
                variant={:compact}
                width="7rem"
                class="flex-none justify-end tabular-nums whitespace-nowrap"
              >
                {round(video.avg_completion * 100)}%
              </.data_table_cell>
            </.data_table_row>
          </.async_result>
        </.data_table>
      </div>
    </div>
    """
  end

  defp sort_columns do
    [
      {"views", gettext("Views"), "6rem"},
      {"watch_time", gettext("Watch time"), "7rem"},
      {"completion", gettext("Completion"), "7rem"}
    ]
  end

  defp sort_path(path, current_sort, direction, sort) do
    {next_sort, next_direction} = next_sort(current_sort, direction, sort)
    path.(next_sort, next_direction)
  end

  defp next_sort(sort, "desc", sort), do: {sort, "asc"}
  defp next_sort(sort, "asc", sort), do: {default_sort(), "desc"}
  defp next_sort(_current_sort, _direction, sort), do: {sort, "desc"}

  defp sort_rows(videos, sort, direction) do
    rows = sort_rows(videos, sort)
    if direction == "asc", do: Enum.reverse(rows), else: rows
  end

  # The caller selects the 25 most viewed videos before this display-only sort.
  defp sort_rows(videos, "watch_time"),
    do: Enum.sort_by(videos, &{-&1.watch_ms, -&1.views, &1.embed_hash})

  defp sort_rows(videos, "completion"),
    do: Enum.sort_by(videos, &{-&1.avg_completion, -&1.views, &1.embed_hash})

  defp sort_rows(videos, _sort), do: Enum.sort_by(videos, &{-&1.views, &1.embed_hash})

  defp format_watch_time(ms) when ms >= 3_600_000,
    do: "#{format_number(round(ms / 3_600_000))} h"

  defp format_watch_time(ms), do: "#{format_number(round(ms / 60_000))} min"

  defp format_number(number), do: Formatter.format_number(number)
end
