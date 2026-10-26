defmodule MaveCoreWeb.Dashboard.Data.OverviewComponents do
  @moduledoc false

  use MaveCoreWeb, :html
  import MaveCoreWeb.DashboardComponents, except: [icon: 1]

  alias MaveCore.Analytics.Overview
  alias MaveCoreWeb.Formatter
  alias Phoenix.LiveView.{AsyncResult, JS}

  @period_labels [
    {"today", "Today"},
    {"week", "This week"},
    {"month", "This month"},
    {"year", "This year"}
  ]

  attr(:period, :string, required: true)
  attr(:path, :any, required: true, doc: "function that builds the path for a period")

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

  attr(:overview, AsyncResult, required: true)
  attr(:period, :string, required: true)

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
        delta={kpi_delta(@data, :views)}
        delta_title={versus(@period)}
        delta_tone={kpi_tone(@data, :views)}
      />
      <.video_metric_card
        label={gettext("Watch time")}
        unit={watch_time_unit(@data)}
        value={kpi_value(@data, :watch_ms)}
        loading={@loading}
        delta={kpi_delta(@data, :watch_ms)}
        delta_title={versus(@period)}
        delta_tone={kpi_tone(@data, :watch_ms)}
      />
      <.video_metric_card
        label={gettext("Average per view")}
        unit={gettext("watched")}
        value={kpi_value(@data, :avg_watch_ms)}
        loading={@loading}
        delta={kpi_delta(@data, :avg_watch_ms)}
        delta_title={versus(@period)}
        delta_tone={kpi_tone(@data, :avg_watch_ms)}
      />
      <.video_metric_card
        label={gettext("Average completion")}
        unit={gettext("of each video")}
        value={kpi_value(@data, :avg_completion)}
        loading={@loading}
        delta={kpi_delta(@data, :avg_completion)}
        delta_title={gettext("Percentage points") <> " · " <> versus(@period)}
        delta_tone={kpi_tone(@data, :avg_completion)}
      />
    </div>
    """
  end

  attr(:overview, AsyncResult, required: true)
  attr(:period, :string, required: true)

  def trend(assigns) do
    assigns = assign(assigns, :loading_chart, chart(Overview.empty(assigns.period)))

    ~H"""
    <.video_data_section>
      <.async_result :let={overview} assign={@overview}>
        <:loading>
          <.trend_chart chart={@loading_chart} loading />
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

  attr(:chart, :map, required: true)
  attr(:loading, :boolean, default: false)

  defp trend_chart(assigns) do
    ~H"""
    <div
      id={if @loading, do: "data-trend-loading", else: "data-trend"}
      class="w-full h-60 flex flex-col"
      role={if @loading, do: "status", else: "group"}
      aria-label={if @loading, do: gettext("Loading history"), else: gettext("Views per period")}
    >
      <.plot_chart chart={@chart} loading={@loading} />
      <span :if={@loading} class="sr-only">{gettext("Loading data")}</span>
      <span :if={!@loading && @chart.empty?} class="sr-only">{gettext("No views in this period yet")}</span>
    </div>
    """
  end

  attr(:chart, :map, required: true)
  attr(:loading, :boolean, default: false)

  defp plot_chart(assigns) do
    ~H"""
    <div class="flex min-h-0 flex-1 gap-3 px-4 pt-10">
      <div
        class="relative w-8 shrink-0 text-xs font-medium tabular-nums text-stone-400"
        aria-hidden="true"
      >
        <span
          :for={
            {value, position} <- [
              {@chart.ceiling, "top-0 -translate-y-1/2"},
              {@chart.ceiling / 2, "top-1/2 -translate-y-1/2"},
              {0, "bottom-0 translate-y-1/2"}
            ]
          }
          class={["absolute right-0", position]}
        >
          <span :if={@loading} class="data-loading-skeleton block h-3 w-6 rounded-full"></span>
          <span :if={!@loading}>{axis_number(value)}</span>
        </span>
      </div>
      <div
        id="data-trend-plot"
        class="relative flex min-w-0 flex-1 items-end"
        aria-hidden={@loading && "true"}
      >
        <button
          :for={bar <- @chart.bars}
          id={"data-trend-bar-#{bar.index}"}
          type="button"
          class="group static z-10 flex h-full min-w-0 flex-1 items-end justify-center rounded-sm hover:z-30 focus:z-20 focus:outline-none"
          aria-label={if !@loading, do: bar.title}
          disabled={@loading}
          phx-click={JS.focus(to: "#data-trend-bar-#{bar.index}")}
          phx-keydown={JS.focus(to: "#data-period-switch a[aria-current]")}
          phx-key="Escape"
        >
          <span
            :if={!@loading}
            aria-hidden="true"
            class="data-history-tooltip pointer-events-none absolute z-30 w-44 max-w-full rounded-lg bg-white px-3 py-2 text-left text-xs leading-tight shadow-sm shadow-stone-100 ring-1 ring-stone-200/70 opacity-0 transition-opacity group-hover:opacity-100 group-focus:opacity-100"
            style={"left: clamp(0px, calc(#{bar.position}% - 5.5rem), max(0px, calc(100% - 11rem))); bottom: min(calc(#{bar.height}% + 10px), calc(100% - 80px))"}
          >
            <span class="block text-xs text-stone-400">{bar.date_label}</span>
            <span class="mt-1 block text-sm font-medium text-stone-500">{format_number(bar.views)} {gettext(
              "views"
            )}</span>
            <span class="mt-1 block text-xs text-stone-400">{bar.watch_label} {gettext("watched")}</span>
          </span>
          <span
            aria-hidden="true"
            class={[
              "flex h-full w-1 items-end overflow-hidden rounded-full",
              @loading && "data-loading-skeleton",
              !@loading && "bg-stone-50"
            ]}
          >
            <span
              :if={!@loading}
              class="w-full rounded-full bg-blue-500 transition-colors group-hover:bg-blue-600 group-focus:bg-blue-600"
              style={"height: #{bar.height}%; min-height: #{if bar.views > 0, do: 2, else: 0}px"}
            ></span>
          </span>
        </button>
      </div>
    </div>
    <div
      id="data-trend-axis"
      class="relative ml-[3.75rem] mr-4 h-10 flex-none text-xs font-medium tabular-nums text-stone-400"
      aria-hidden="true"
    >
      <span
        :for={bar <- @chart.bars}
        :if={bar.label != ""}
        class={[
          "absolute top-3 whitespace-nowrap",
          !bar.first? && !bar.last? && "-translate-x-1/2",
          bar.last? && "-translate-x-full"
        ]}
        style={"left: #{bar.position}%"}
      >{bar.label}</span>
    </div>
    """
  end

  @doc false
  def chart(%{series: series, bucket: bucket}) do
    max_views = max(Enum.max(Enum.map(series, & &1.views), fn -> 0 end), 1)
    count = length(series)
    magnitude = trunc(:math.pow(10, floor(:math.log10(max_views))))
    ceiling = max(ceil(max_views / magnitude) * magnitude, 2)

    bars =
      series
      |> Enum.with_index()
      |> Enum.map(fn {point, index} ->
        %{
          index: index,
          first?: index == 0,
          last?: index == count - 1,
          position: 100 * (index + 0.5) / count,
          views: point.views,
          date_label: bucket_label(point.start, bucket, :long),
          watch_label: format_watch_time(point.watch_ms),
          height: 100 * point.views / ceiling,
          label:
            if(axis_tick?(point.start, bucket, index, count),
              do: bucket_label(point.start, bucket, :short),
              else: ""
            ),
          title:
            "#{bucket_label(point.start, bucket, :long)} · #{format_number(point.views)} #{gettext("views")} · #{format_watch_time(point.watch_ms)}"
        }
      end)

    %{
      bars: bars,
      ceiling: ceiling,
      empty?: Enum.all?(series, &(&1.views == 0))
    }
  end

  defp axis_tick?(_start, _bucket, _index, count) when count <= 12, do: true
  defp axis_tick?(_start, _bucket, index, count) when index == 0 or index == count - 1, do: true
  defp axis_tick?(_start, _bucket, index, count) when index < 3 or index > count - 4, do: false
  defp axis_tick?(start, :day, _index, _count), do: Date.day_of_week(DateTime.to_date(start)) == 1
  defp axis_tick?(start, :hour, _index, _count), do: rem(start.hour, 6) == 0

  defp axis_number(value) when value >= 1000 do
    number = Float.round(value / 1000, 1)
    format_number(if number == trunc(number), do: trunc(number), else: number) <> "k"
  end

  defp axis_number(value),
    do: format_number(if value == trunc(value), do: trunc(value), else: value)

  defp bucket_label(start, :hour, :short), do: Calendar.strftime(start, "%H:00")
  defp bucket_label(start, :hour, :long), do: Calendar.strftime(start, "%-d %b · %H:00")
  defp bucket_label(start, :day, :short), do: Calendar.strftime(start, "%-d %b")
  defp bucket_label(start, :day, :long), do: Calendar.strftime(start, "%a %-d %b")
  defp bucket_label(start, :month, :short), do: Calendar.strftime(start, "%b")
  defp bucket_label(start, :month, :long), do: Calendar.strftime(start, "%B %Y")

  defp kpi_value(false, _key), do: "0"
  defp kpi_value(%{current: current}, :views), do: format_number(current.views)
  defp kpi_value(%{current: current}, :watch_ms), do: watch_time_number(current.watch_ms)
  defp kpi_value(%{current: current}, :avg_watch_ms), do: format_duration(current.avg_watch_ms)

  defp kpi_value(%{current: current}, :avg_completion),
    do: "#{round(current.avg_completion * 100)}%"

  defp watch_time_unit(false), do: gettext("hours")

  defp watch_time_unit(%{current: %{watch_ms: watch_ms}}) when watch_ms >= 3_600_000,
    do: gettext("hours")

  defp watch_time_unit(_data), do: gettext("minutes")

  defp watch_time_number(watch_ms) when watch_ms >= 3_600_000,
    do: format_number(round(watch_ms / 3_600_000))

  defp watch_time_number(watch_ms), do: format_number(round(watch_ms / 60_000))

  defp format_watch_time(watch_ms) when watch_ms >= 36_000_000,
    do: "#{format_number(round(watch_ms / 3_600_000))} h"

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

  defp kpi_delta(false, _key), do: nil
  defp kpi_delta(%{current: %{views: 0}}, _key), do: nil

  defp kpi_delta(%{current: current, previous: previous}, :avg_completion) do
    if previous.views == 0 do
      nil
    else
      points = Float.round((current.avg_completion - previous.avg_completion) * 100, 1)
      format_delta(points)
    end
  end

  defp kpi_delta(%{current: current, previous: previous}, key) do
    case Map.fetch!(previous, key) do
      0 ->
        nil

      before ->
        change = Float.round((Map.fetch!(current, key) - before) / before * 100, 1)
        format_delta(change)
    end
  end

  defp format_delta(change) when change == -100, do: nil
  defp format_delta(change), do: "#{arrow(change)} #{format_number(abs(change))}%"

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

  defp versus("today"), do: gettext("vs yesterday at the same time")
  defp versus("week"), do: gettext("vs the same part of last week")
  defp versus("month"), do: gettext("vs the same part of last month")
  defp versus("year"), do: gettext("vs same period last year")

  defp period_label("Today"), do: gettext("Today")
  defp period_label("This week"), do: gettext("This week")
  defp period_label("This month"), do: gettext("This month")
  defp period_label("This year"), do: gettext("This year")

  defp format_number(number), do: Formatter.format_number(number)
end
