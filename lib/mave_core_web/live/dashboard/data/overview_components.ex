defmodule MaveCoreWeb.Dashboard.Data.OverviewComponents do
  @moduledoc false

  use MaveCoreWeb, :html
  import MaveCoreWeb.DashboardComponents, except: [icon: 1]

  alias MaveCoreWeb.Formatter
  alias Phoenix.LiveView.AsyncResult

  @period_labels [
    {"24h", "24 hours"},
    {"7d", "7 days"},
    {"30d", "30 days"},
    {"12m", "12 months"}
  ]

  @chart_width 960
  @chart_height 200
  @chart_left 44
  @chart_right 8
  @chart_top 12
  @chart_bottom 26

  attr :period, :string, required: true
  attr :path, :any, required: true, doc: "function that builds the path for a period"

  def period_switch(assigns) do
    assigns = assign(assigns, :periods, @period_labels)

    ~H"""
    <nav
      id="data-period-switch"
      aria-label={gettext("Period")}
      class="flex-none flex items-center rounded-full bg-white ring-1 ring-stone-200/70 p-0.5 text-xs"
    >
      <.link
        :for={{period, label} <- @periods}
        patch={@path.(period)}
        aria-current={if period == @period, do: "page"}
        class={[
          "px-3 py-1 rounded-full select-none transition-colors",
          period == @period && "bg-stone-100 text-stone-600 cursor-default",
          period != @period && "text-stone-400 hover:text-stone-600"
        ]}
      >
        {period_label(label)}
      </.link>
    </nav>
    """
  end

  attr :overview, AsyncResult, required: true
  attr :period, :string, required: true

  def kpis(assigns) do
    assigns =
      assign(assigns,
        loading: assigns.overview.loading != nil,
        data: assigns.overview.ok? && assigns.overview.result
      )

    ~H"""
    <div id="data-kpis" class="grid grid-cols-2 xl:grid-cols-4 gap-4 font-sans">
      <.video_metric_card
        label={gettext("Views")}
        value={kpi_value(@data, :views)}
        loading={@loading}
        delta={kpi_delta(@data, :views, @period)}
        delta_tone={kpi_tone(@data, :views)}
      />
      <.video_metric_card
        label={gettext("Watch time")}
        unit={watch_time_unit(@data)}
        value={kpi_value(@data, :watch_ms)}
        loading={@loading}
        delta={kpi_delta(@data, :watch_ms, @period)}
        delta_tone={kpi_tone(@data, :watch_ms)}
      />
      <.video_metric_card
        label={gettext("Average per view")}
        unit={gettext("watched")}
        value={kpi_value(@data, :avg_watch_ms)}
        loading={@loading}
        delta={kpi_delta(@data, :avg_watch_ms, @period)}
        delta_tone={kpi_tone(@data, :avg_watch_ms)}
      />
      <.video_metric_card
        label={gettext("Average completion")}
        unit={gettext("of each video")}
        value={kpi_value(@data, :avg_completion)}
        loading={@loading}
        delta={kpi_delta(@data, :avg_completion, @period)}
        delta_tone={kpi_tone(@data, :avg_completion)}
      />
    </div>
    """
  end

  attr :overview, AsyncResult, required: true

  def trend(assigns) do
    ~H"""
    <.video_data_section>
      <.async_result :let={overview} assign={@overview}>
        <:loading>
          <div
            id="data-trend-loading"
            class="h-56 flex items-end gap-2 px-12 pb-8 pt-6"
            role="status"
            aria-label={gettext("Loading history")}
          >
            <div
              :for={height <- [42, 67, 52, 78, 58, 86, 70, 47, 62, 38, 55, 31, 64, 49, 72]}
              class="data-loading-skeleton flex-1 rounded-sm"
              style={"height: #{height}%"}
              aria-hidden="true"
            >
            </div>
            <span class="sr-only">{gettext("Loading data")}</span>
          </div>
        </:loading>
        <:failed>
          <div class="py-16 text-center text-sm font-medium text-stone-400">
            {gettext("Data is unavailable")}
          </div>
        </:failed>
        <.trend_chart chart={chart(overview)} />
      </.async_result>
    </.video_data_section>
    """
  end

  attr :overview, AsyncResult, required: true

  def reach(assigns) do
    ~H"""
    <.video_data_section label={gettext("How far people watch")}>
      <.async_result :let={overview} assign={@overview}>
        <:loading>
          <div id="data-reach-loading" class="grid gap-3 p-4" role="status">
            <div
              :for={width <- [100, 80, 62, 45, 33]}
              class="data-loading-skeleton h-2.5 rounded-full"
              style={"width: #{width}%"}
              aria-hidden="true"
            >
            </div>
            <span class="sr-only">{gettext("Loading data")}</span>
          </div>
        </:loading>
        <:failed>
          <div class="py-8 text-center text-sm font-medium text-stone-400">
            {gettext("Data is unavailable")}
          </div>
        </:failed>
        <div id="data-reach" class="grid gap-3 p-4">
          <div
            :for={step <- overview.reach}
            class="grid grid-cols-[5.5rem_minmax(0,1fr)_3rem] items-center gap-3 text-xs text-stone-400"
          >
            <span>{reach_label(step.percent)}</span>
            <div class="h-2.5 rounded-full bg-stone-50 overflow-hidden">
              <div
                class="h-full rounded-full bg-blue-500"
                style={"width: #{round(step.share * 100)}%"}
              >
              </div>
            </div>
            <span class="text-right text-stone-500 tabular-nums">{round(step.share * 100)}%</span>
          </div>
        </div>
      </.async_result>
    </.video_data_section>
    """
  end

  attr :overview, AsyncResult, required: true

  def hours(assigns) do
    ~H"""
    <.video_data_section label={gettext("When people watch")}>
      <.async_result :let={overview} assign={@overview}>
        <:loading>
          <div id="data-hours-loading" class="p-4" role="status">
            <div class="data-loading-skeleton h-36 rounded-md" aria-hidden="true"></div>
            <span class="sr-only">{gettext("Loading data")}</span>
          </div>
        </:loading>
        <:failed>
          <div class="py-8 text-center text-sm font-medium text-stone-400">
            {gettext("Data is unavailable")}
          </div>
        </:failed>
        <div
          id="data-hours"
          class="grid grid-cols-[2rem_repeat(24,minmax(0,1fr))] gap-0.5 p-4 text-[10px] text-stone-300"
        >
          <span></span>
          <span :for={hour <- 0..23} class="text-center">{if rem(hour, 6) == 0, do: hour}</span>
          <%= for {weekday, label} <- weekdays() do %>
            <span class="self-center">{label}</span>
            <div
              :for={hour <- 0..23}
              class="aspect-square rounded-sm bg-blue-500"
              style={"opacity: #{hour_opacity(overview.hours, weekday, hour)}"}
              title={"#{label} #{hour}:00 · #{format_number(Map.get(overview.hours, {weekday, hour}, 0))} #{gettext("views")}"}
            >
            </div>
          <% end %>
        </div>
        <p class="px-4 pb-3 text-xs text-stone-300">{gettext("Hours in UTC")}</p>
      </.async_result>
    </.video_data_section>
    """
  end

  defp reach_label(0), do: gettext("Started")
  defp reach_label(95), do: gettext("Finished")
  defp reach_label(percent), do: "#{percent}%"

  defp weekdays do
    [
      {1, gettext("Mon")},
      {2, gettext("Tue")},
      {3, gettext("Wed")},
      {4, gettext("Thu")},
      {5, gettext("Fri")},
      {6, gettext("Sat")},
      {7, gettext("Sun")}
    ]
  end

  defp hour_opacity(hours, weekday, hour) do
    busiest = hours |> Map.values() |> Enum.max(fn -> 0 end)

    case Map.get(hours, {weekday, hour}, 0) do
      0 -> 0.06
      views -> Float.round(0.15 + 0.85 * views / busiest, 2)
    end
  end

  attr :chart, :map, required: true

  defp trend_chart(assigns) do
    ~H"""
    <div class="px-4 pt-4 pb-2">
      <div class="flex items-center justify-end gap-4 px-2 pb-2 text-xs text-stone-400">
        <span class="flex items-center gap-1.5">
          <span class="inline-block size-2 rounded-sm bg-blue-500"></span>{gettext("views")}
        </span>
        <span class="flex items-center gap-1.5">
          <span class="inline-block w-3 h-px bg-stone-400"></span>{gettext("watch time")}
        </span>
      </div>
      <svg
        id="data-trend"
        viewBox={"0 0 #{@chart.width} #{@chart.height}"}
        class="w-full h-auto overflow-visible"
        role="img"
        aria-label={gettext("Views and watch time per period")}
      >
        <g :for={tick <- @chart.ticks}>
          <line
            x1={@chart.left}
            x2={@chart.width - @chart.right}
            y1={tick.y}
            y2={tick.y}
            class="stroke-stone-100"
          />
          <text
            x={@chart.left - 8}
            y={tick.y + 3}
            text-anchor="end"
            class="fill-stone-300 text-[10px]"
          >
            {tick.label}
          </text>
        </g>
        <rect
          :for={bar <- @chart.bars}
          x={bar.x}
          y={bar.y}
          width={bar.width}
          height={bar.height}
          rx="1.5"
          class={["fill-blue-500", !bar.last && "opacity-60"]}
          data-views={bar.views}
        >
          <title>{bar.title}</title>
        </rect>
        <polyline
          :if={@chart.line != ""}
          points={@chart.line}
          fill="none"
          class="stroke-stone-400"
          stroke-width="1.5"
          stroke-linejoin="round"
        />
        <text
          :for={label <- @chart.labels}
          x={label.x}
          y={@chart.height - 6}
          text-anchor="middle"
          class="fill-stone-300 text-[10px]"
        >
          {label.text}
        </text>
      </svg>
      <p :if={@chart.empty?} class="pb-4 text-center text-sm text-stone-400">
        {gettext("No views in this period yet")}
      </p>
    </div>
    """
  end

  @doc false
  def chart(%{series: series, bucket: bucket}) do
    count = max(length(series), 1)
    plot_width = @chart_width - @chart_left - @chart_right
    plot_height = @chart_height - @chart_top - @chart_bottom
    slot = plot_width / count
    max_views = series |> Enum.map(& &1.views) |> Enum.max(fn -> 0 end) |> nice_max()
    max_watch = series |> Enum.map(& &1.watch_ms) |> Enum.max(fn -> 0 end)
    y = fn value, max -> @chart_top + plot_height * (1 - value / max) end
    last_index = count - 1

    bars =
      series
      |> Enum.with_index()
      |> Enum.map(fn {point, index} ->
        top = y.(point.views, max_views)

        %{
          x: Float.round(@chart_left + index * slot + slot * 0.15, 2),
          y: Float.round(top, 2),
          width: Float.round(slot * 0.7, 2),
          height: Float.round(@chart_top + plot_height - top, 2),
          views: point.views,
          last: index == last_index,
          title:
            "#{bucket_label(point.start, bucket, :long)} · #{format_number(point.views)} #{gettext("views")} · #{format_watch_time(point.watch_ms)}"
        }
      end)

    line =
      if max_watch > 0 do
        series
        |> Enum.with_index()
        |> Enum.map_join(" ", fn {point, index} ->
          "#{Float.round(@chart_left + index * slot + slot / 2, 2)},#{Float.round(y.(point.watch_ms, max_watch * 1.1), 2)}"
        end)
      else
        ""
      end

    %{
      width: @chart_width,
      height: @chart_height,
      left: @chart_left,
      right: @chart_right,
      ticks:
        Enum.map([0, 0.5, 1], fn share ->
          value = round(max_views * share)
          %{y: Float.round(y.(value, max_views), 2), label: format_number(value)}
        end),
      bars: bars,
      line: line,
      labels: axis_labels(series, bucket, slot),
      empty?: Enum.all?(series, &(&1.views == 0))
    }
  end

  defp axis_labels(series, bucket, slot) do
    every = max(1, div(length(series), 6))
    last_index = length(series) - 1

    series
    |> Enum.with_index()
    |> Enum.filter(fn {_point, index} -> rem(last_index - index, every) == 0 end)
    |> Enum.map(fn {point, index} ->
      %{
        x: Float.round(@chart_left + index * slot + slot / 2, 2),
        text: bucket_label(point.start, bucket, :short)
      }
    end)
  end

  defp bucket_label(start, :hour, _style), do: Calendar.strftime(start, "%H:00")
  defp bucket_label(start, :day, :short), do: Calendar.strftime(start, "%-d %b")
  defp bucket_label(start, :day, :long), do: Calendar.strftime(start, "%a %-d %b")
  defp bucket_label(start, :month, :short), do: Calendar.strftime(start, "%b")
  defp bucket_label(start, :month, :long), do: Calendar.strftime(start, "%B %Y")

  # Rounds the axis maximum up to 1, 2 or 5 times a power of ten.
  defp nice_max(value) when value <= 4, do: 4

  defp nice_max(value) do
    magnitude = :math.pow(10, floor(:math.log10(value)))
    step = Enum.find([1, 2, 5, 10], &(&1 * magnitude >= value))
    round(step * magnitude)
  end

  defp kpi_value(false, _key), do: "0"
  defp kpi_value(%{current: current}, :views), do: format_number(current.views)
  defp kpi_value(%{current: current}, :watch_ms), do: watch_time_number(current.watch_ms)
  defp kpi_value(%{current: current}, :avg_watch_ms), do: format_duration(current.avg_watch_ms)

  defp kpi_value(%{current: current}, :avg_completion),
    do: "#{round(current.avg_completion * 100)}%"

  defp watch_time_unit(%{current: %{watch_ms: watch_ms}}) when watch_ms >= 3_600_000,
    do: gettext("hours")

  defp watch_time_unit(_data), do: gettext("minutes")

  defp watch_time_number(watch_ms) when watch_ms >= 3_600_000,
    do: format_number(round(watch_ms / 3_600_000))

  defp watch_time_number(watch_ms), do: format_number(round(watch_ms / 60_000))

  defp format_watch_time(watch_ms) when watch_ms >= 3_600_000,
    do: "#{format_number(Float.round(watch_ms / 3_600_000, 1))} h"

  defp format_watch_time(watch_ms), do: "#{format_number(round(watch_ms / 60_000))} min"

  defp format_duration(ms) do
    seconds = div(ms, 1000)
    {hours, rest} = {div(seconds, 3600), rem(seconds, 3600)}
    {minutes, seconds} = {div(rest, 60), rem(rest, 60)}
    padded = &String.pad_leading(Integer.to_string(&1), 2, "0")

    if hours > 0,
      do: "#{hours}:#{padded.(minutes)}:#{padded.(seconds)}",
      else: "#{minutes}:#{padded.(seconds)}"
  end

  defp kpi_delta(false, _key, _period), do: nil

  defp kpi_delta(%{current: current, previous: previous}, :avg_completion, period) do
    if previous.views == 0 do
      nil
    else
      points = Float.round((current.avg_completion - previous.avg_completion) * 100, 1)
      "#{arrow(points)} #{format_number(abs(points))} pt #{versus(period)}"
    end
  end

  defp kpi_delta(%{current: current, previous: previous}, key, period) do
    case Map.fetch!(previous, key) do
      0 ->
        nil

      before ->
        change = Float.round((Map.fetch!(current, key) - before) / before * 100, 1)
        "#{arrow(change)} #{format_number(abs(change))}% #{versus(period)}"
    end
  end

  defp kpi_tone(false, _key), do: :flat

  defp kpi_tone(%{current: current, previous: previous}, key) do
    case {previous.views, Map.fetch!(current, key) - Map.fetch!(previous, key)} do
      {0, _} -> :flat
      {_, diff} when diff > 0 -> :up
      {_, diff} when diff < 0 -> :down
      _ -> :flat
    end
  end

  defp arrow(change) when change > 0, do: "▲"
  defp arrow(change) when change < 0, do: "▼"
  defp arrow(_change), do: "±"

  defp versus("24h"), do: gettext("vs previous 24 hours")
  defp versus("7d"), do: gettext("vs previous 7 days")
  defp versus("30d"), do: gettext("vs previous 30 days")
  defp versus("12m"), do: gettext("vs previous 12 months")

  defp period_label("24 hours"), do: gettext("24 hours")
  defp period_label("7 days"), do: gettext("7 days")
  defp period_label("30 days"), do: gettext("30 days")
  defp period_label("12 months"), do: gettext("12 months")

  defp format_number(number), do: Formatter.format_number(number)
end
