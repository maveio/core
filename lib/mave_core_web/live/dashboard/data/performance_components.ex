defmodule MaveCoreWeb.Dashboard.Data.PerformanceComponents do
  @moduledoc false

  use MaveCoreWeb, :html
  import MaveCoreWeb.DashboardComponents, except: [icon: 1]

  alias MaveCore.Analytics.Performance
  alias MaveCoreWeb.DashboardRoutes
  alias MaveCoreWeb.Formatter
  alias Phoenix.LiveView.{AsyncResult, JS}

  def dimensions, do: Enum.map(Performance.dimensions(), &Atom.to_string/1)
  def default_dimension, do: "video"

  attr :report, AsyncResult, required: true
  attr :period, :string, required: true
  attr :dimension, :string, required: true
  attr :dimension_path, :any, required: true, doc: "function that builds the path for a dimension"
  attr :current_space, :any, required: true
  attr :route_scope, :atom, required: true

  def performance(assigns) do
    assigns =
      assign(assigns,
        loading: assigns.report.loading != nil,
        data: assigns.report.ok? && assigns.report.result,
        loading_report: Performance.empty(assigns.period)
      )

    ~H"""
    <div class="mb-6">
      <.subtitle label={gettext("Viewer experience")} icon="hero-play-circle" />
    </div>

    <div id="performance-experience" class="grid grid-cols-2 xl:grid-cols-4 gap-4 font-sans">
      <.video_metric_card
        :for={card <- experience_cards(@data)}
        label={card.label}
        unit={card.unit}
        value={card.value}
        delta={card.detail}
        loading={@loading}
      />
    </div>

    <div class="mt-10 mb-6">
      <.subtitle label={gettext("Delivery")} icon="hero-server-stack" />
    </div>

    <div
      :if={@data && !@data.delivery}
      id="performance-delivery-empty"
      class="rounded-lg px-6 py-8 text-sm text-stone-400 shadow-sm shadow-stone-100 ring-1 ring-stone-200/50"
    >
      <div class="font-medium text-stone-500">
        {gettext("No delivery telemetry in this period")}
      </div>
      <p class="mt-1 max-w-2xl">
        {gettext(
          "Cache hits, origin traffic, latency and error rates come from the CDN or edge server, not from the player. Once its request logs are sent to this installation, they appear here next to the viewer figures."
        )}
      </p>
    </div>

    <div
      :if={!@data || @data.delivery}
      id="performance-delivery"
      class="grid grid-cols-2 xl:grid-cols-4 gap-4 font-sans"
    >
      <.video_metric_card
        :for={card <- delivery_cards(@data)}
        label={card.label}
        unit={card.unit}
        value={card.value}
        delta={card.detail}
        loading={@loading}
      />
    </div>

    <.divider />

    <div class="mb-6">
      <.subtitle label={gettext("History")} icon="hero-chart-bar" />
    </div>

    <.async_result :let={report} assign={@report}>
      <:loading>
        <div id="performance-history-loading" role="status">
          <.history charts={charts(@loading_report)} loading />
          <span class="sr-only">{gettext("Loading data")}</span>
        </div>
      </:loading>
      <:failed>
        <div class="py-16 text-center text-sm font-medium text-stone-400">
          {gettext("Data is unavailable")}
        </div>
      </:failed>
      <.history charts={charts(report)} />

      <.divider />

      <div class="mb-6">
        <.subtitle label={gettext("Diagnosis")} icon="hero-magnifying-glass" />
      </div>

      <div class="grid grid-cols-1 xl:grid-cols-3 gap-4">
        <div class="xl:col-span-2">
          <.findings report={report} />
        </div>
        <.resolutions report={report} />
      </div>

      <div class="mt-10 mb-6">
        <.subtitle label={gettext("Breakdown")} icon="hero-table-cells">
          <.dimension_switch dimension={@dimension} path={@dimension_path} />
        </.subtitle>
      </div>

      <.breakdown
        report={report}
        dimension={@dimension}
        current_space={@current_space}
        route_scope={@route_scope}
      />
    </.async_result>
    """
  end

  attr :charts, :list, required: true
  attr :loading, :boolean, default: false

  defp history(assigns) do
    ~H"""
    <div id="performance-history" class="grid grid-cols-1 md:grid-cols-3 gap-4">
      <.video_data_section :for={chart <- @charts} label={chart.label}>
        <div
          id={"performance-chart-#{chart.id}"}
          class="px-4 pt-3 pb-2"
          role="group"
          aria-label={chart.label}
        >
          <div class="flex h-9 items-start justify-between text-xs text-stone-400">
            <span :if={!@loading && chart.empty?}>{gettext("No data yet")}</span>
            <span :if={!@loading && !chart.empty?} class="tabular-nums">
              {gettext("peak")} {chart.peak_label}
            </span>
          </div>
          <div class="relative flex h-24 items-end" aria-hidden={@loading && "true"}>
            <button
              :for={point <- chart.points}
              id={"performance-chart-#{chart.id}-bar-#{point.index}"}
              type="button"
              class="group static flex h-full min-w-0 flex-1 items-end justify-center rounded-sm focus:outline-none"
              aria-label={if !@loading, do: point.title}
              disabled={@loading}
              phx-click={JS.focus(to: "#performance-chart-#{chart.id}-bar-#{point.index}")}
            >
              <span
                :if={!@loading}
                aria-hidden="true"
                class="pointer-events-none absolute -top-10 z-30 w-36 max-w-full rounded-lg bg-white px-2.5 py-1.5 text-left text-xs leading-tight shadow-sm shadow-stone-100 ring-1 ring-stone-200/70 opacity-0 transition-opacity group-hover:opacity-100 group-focus:opacity-100"
                style={"left: clamp(0px, calc(#{point.position}% - 4.5rem), max(0px, calc(100% - 9rem)))"}
              >
                <span class="block text-stone-400">{point.date_label}</span>
                <span class="mt-0.5 block text-sm font-medium text-stone-500">
                  {point.value_label}
                </span>
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
                  :if={!@loading && point.value}
                  class="w-full rounded-full bg-blue-500 transition-colors group-hover:bg-blue-600 group-focus:bg-blue-600"
                  style={"height: #{point.height}%; min-height: 2px"}
                ></span>
              </span>
            </button>
          </div>
          <div class="mt-2 flex justify-between text-xs font-medium tabular-nums text-stone-400">
            <span>{chart.first_label}</span>
            <span>{chart.last_label}</span>
          </div>
        </div>
      </.video_data_section>
    </div>
    """
  end

  attr :report, :map, required: true

  defp findings(assigns) do
    ~H"""
    <.video_data_section label={gettext("What stands out")}>
      <div id="performance-findings" class="divide-y divide-stone-100">
        <div
          :if={@report.findings == []}
          id="performance-findings-empty"
          class="px-4 py-10 text-center text-sm text-stone-400"
        >
          <div class="font-medium">
            {if @report.experience.attempts == 0,
              do: gettext("No playback measurements yet"),
              else: gettext("Nothing stands out")}
          </div>
          <p class="mx-auto mt-1 max-w-md">
            {if @report.experience.attempts == 0,
              do:
                gettext(
                  "Startup time, buffering and failures appear once players report playback quality."
                ),
              else:
                gettext(
                  "No video, device, browser or region with enough plays is clearly worse than the space as a whole."
                )}
          </p>
        </div>
        <div
          :for={finding <- @report.findings}
          id={"performance-finding-#{finding.dimension}-#{finding.key}"}
          class="px-4 py-3.5"
        >
          <div class="flex items-baseline gap-2">
            <span class="min-w-0 truncate text-sm font-medium text-stone-600">
              {finding.label}
            </span>
            <span class="flex-none rounded-full bg-stone-100 px-2 py-0.5 text-xs text-stone-500">
              {dimension_label(finding.dimension)}
            </span>
            <span class="flex-none text-xs tabular-nums text-stone-400">
              {format_number(finding.attempts)} {gettext("plays")}
            </span>
          </div>
          <p :for={symptom <- finding.symptoms} class="mt-1 text-sm text-stone-500">
            {symptom_text(symptom)}
          </p>
          <p :for={cause <- finding.causes} class="mt-1 text-sm text-stone-400">
            {cause_text(cause)}
          </p>
        </div>
      </div>
    </.video_data_section>
    """
  end

  attr :report, :map, required: true

  defp resolutions(assigns) do
    ~H"""
    <.video_data_section label={gettext("Delivered resolution")}>
      <div id="performance-resolutions" class="flex flex-col gap-3 p-4">
        <div
          :if={@report.resolutions == []}
          class="py-6 text-center text-sm font-medium text-stone-400"
        >
          {gettext("No data yet")}
        </div>
        <div
          :for={resolution <- @report.resolutions}
          class="grid grid-cols-[3.5rem_minmax(0,1fr)_3rem] items-center gap-3 text-xs text-stone-400"
        >
          <span class="tabular-nums">{resolution.height}p</span>
          <div class="h-2.5 overflow-hidden rounded-full bg-stone-50">
            <div
              class="h-full rounded-full bg-blue-500"
              style={"width: #{round(resolution.share * 100)}%"}
            >
            </div>
          </div>
          <span class="text-right tabular-nums">{round(resolution.share * 100)}%</span>
        </div>
        <p :if={@report.resolutions != []} class="text-xs text-stone-400">
          {gettext("Share of watch time per rendition.")}
        </p>
      </div>
    </.video_data_section>
    """
  end

  attr :dimension, :string, required: true
  attr :path, :any, required: true

  defp dimension_switch(assigns) do
    ~H"""
    <nav
      id="performance-dimension-switch"
      aria-label={gettext("Break down by")}
      class="flex-none flex items-center rounded-full bg-white ring-1 ring-stone-200/70 p-0.5 text-xs"
    >
      <.link
        :for={dimension <- dimensions()}
        patch={@path.(dimension)}
        data-dimension={dimension}
        aria-current={if dimension == @dimension, do: "page"}
        class={[
          "px-3 py-1 rounded-full select-none transition-colors",
          dimension == @dimension && "bg-stone-100 text-stone-600 cursor-default",
          dimension != @dimension && "text-stone-400 hover:text-stone-600"
        ]}
      >
        {dimension_label(dimension)}
      </.link>
    </nav>
    """
  end

  attr :report, :map, required: true
  attr :dimension, :string, required: true
  attr :current_space, :any, required: true
  attr :route_scope, :atom, required: true

  defp breakdown(assigns) do
    dimension = Enum.find(Performance.dimensions(), &(Atom.to_string(&1) == assigns.dimension))

    assigns =
      assign(assigns,
        rows: Map.fetch!(assigns.report.breakdowns, dimension),
        columns: columns(dimension),
        flagged: flagged(assigns.report.findings, dimension)
      )

    ~H"""
    <div id="performance-breakdown" class="overflow-x-auto">
      <div class="min-w-[58rem]">
        <.data_table variant={:compact}>
          <:header>
            <.data_table_header_cell variant={:compact} class="min-w-0 flex-1">
              {dimension_label(@dimension)}
            </.data_table_header_cell>
            <.data_table_header_cell
              :for={column <- @columns}
              variant={:compact}
              width="5.75rem"
              align="right"
              class="flex-none whitespace-nowrap"
            >
              <span title={column.help}>{column.label}</span>
            </.data_table_header_cell>
          </:header>

          <div
            :if={@rows == []}
            class="flex flex-col items-center justify-center py-8 text-stone-400"
          >
            <.icon name="hero-table-cells" class="h-6 w-6 mb-2 opacity-50" />
            <div class="text-sm font-medium">{gettext("No data yet")}</div>
          </div>

          <.data_table_row
            :for={row <- @rows}
            variant={:compact}
            id={"performance-row-#{@dimension}-#{row_id(row.key)}"}
          >
            <.data_table_cell variant={:compact} class="min-w-0 flex-1" truncate>
              <.link
                :if={row[:id]}
                navigate={
                  DashboardRoutes.video_path(@current_space, row.id, :all, scope: @route_scope)
                }
                class="block w-full truncate text-stone-400 hover:text-stone-600"
              >
                {row.label}
              </.link>
              <span :if={!row[:id]} class="block w-full truncate">{row.label}</span>
            </.data_table_cell>
            <.data_table_cell
              :for={column <- @columns}
              variant={:compact}
              width="5.75rem"
              class="flex-none justify-end tabular-nums whitespace-nowrap"
            >
              <span
                data-flagged={column.id in Map.get(@flagged, row.key, []) && "true"}
                title={
                  column.id in Map.get(@flagged, row.key, []) &&
                    gettext("Clearly worse than the space as a whole")
                }
                class={column.id in Map.get(@flagged, row.key, []) && "font-medium text-red-500"}
              >
                {column.value.(row)}
              </span>
            </.data_table_cell>
          </.data_table_row>
        </.data_table>
      </div>
    </div>
    """
  end

  defp experience_cards(false), do: experience_cards(Performance.empty("today"))

  defp experience_cards(%{experience: experience, resolutions: resolutions}) do
    [
      %{
        label: gettext("Startup time"),
        unit: gettext("median until the first frame"),
        value: duration(experience.startup_p50_ms),
        detail:
          experience.startup_p95_ms &&
            gettext("95% start within %{time}", time: duration(experience.startup_p95_ms))
      },
      %{
        label: gettext("Rebuffering"),
        unit: gettext("of watch time spent buffering"),
        value: percent(experience.rebuffer_ratio),
        detail:
          experience.attempts > 0 &&
            gettext("%{stalled} of %{plays} plays stalled",
              stalled: format_number(experience.rebuffered_attempts),
              plays: format_number(experience.attempts)
            )
      },
      %{
        label: gettext("Playback failures"),
        unit: gettext("of plays ended in an error"),
        value: percent(experience.failure_rate),
        detail:
          experience.attempts > 0 &&
            gettext("%{startup} at startup · %{playback} while playing",
              startup: format_number(experience.startup_failures),
              playback: format_number(experience.playback_failures)
            )
      },
      %{
        label: gettext("Delivered quality"),
        unit: gettext("average bitrate"),
        value: bitrate(experience.avg_bitrate),
        detail: top_resolution(resolutions)
      }
    ]
    |> Enum.map(&Map.update!(&1, :detail, fn detail -> detail || nil end))
  end

  defp delivery_cards(%{delivery: %{} = delivery}) do
    [
      %{
        label: gettext("Cache hit ratio"),
        unit: gettext("of cacheable requests"),
        value: percent(delivery.cache_hit_ratio),
        detail: gettext("%{misses} cache misses", misses: format_number(delivery.misses))
      },
      %{
        label: gettext("Origin traffic"),
        unit: gettext("fetched from the origin"),
        value: bytes(delivery.origin_bytes),
        detail: gettext("of %{total} delivered", total: bytes(delivery.bytes))
      },
      %{
        label: gettext("Edge latency"),
        unit: gettext("median time to first byte"),
        value: duration(delivery.ttfb_p50_ms),
        detail: gettext("95% within %{time}", time: duration(delivery.ttfb_p95_ms))
      },
      %{
        label: gettext("Delivery errors"),
        unit: gettext("of requests failed"),
        value: percent(delivery.error_rate),
        detail:
          gettext("%{server} server · %{client} client errors",
            server: format_number(delivery.server_errors),
            client: format_number(delivery.client_errors)
          )
      }
    ]
  end

  defp delivery_cards(_loading) do
    for label <- [
          gettext("Cache hit ratio"),
          gettext("Origin traffic"),
          gettext("Edge latency"),
          gettext("Delivery errors")
        ],
        do: %{label: label, unit: " ", value: "–", detail: nil}
  end

  defp top_resolution([]), do: nil

  defp top_resolution(resolutions) do
    top = Enum.max_by(resolutions, & &1.share)

    gettext("%{share} of watch time at %{height}p",
      share: percent(top.share),
      height: top.height
    )
  end

  @doc false
  def charts(%{series: series, bucket: bucket}) do
    [
      {"startup", gettext("Startup time"), &duration/1, :experience, :startup_p50_ms, nil},
      {"rebuffering", gettext("Rebuffering"), &percent/1, :experience, :rebuffer_ratio, nil},
      {"failures", gettext("Playback failures"), &percent/1, :experience, :failure_rate, nil},
      {"cache", gettext("Cache hit ratio"), &percent/1, :delivery, :cache_hit_ratio, 1.0},
      {"latency", gettext("Edge latency (95%)"), &duration/1, :delivery, :ttfb_p95_ms, nil},
      {"errors", gettext("Delivery errors"), &percent/1, :delivery, :error_rate, nil}
    ]
    |> Enum.map(fn {id, label, format, source, metric, ceiling} ->
      values = Enum.map(series, &get_in(&1, [source, metric]))
      chart(id, label, format, series, values, bucket, ceiling)
    end)
  end

  defp chart(id, label, format, series, values, bucket, ceiling) do
    measured = Enum.reject(values, &is_nil/1)
    peak = Enum.max(measured, fn -> 0 end)
    ceiling = ceiling || if(peak > 0, do: peak, else: 1)
    count = length(series)

    points =
      series
      |> Enum.zip(values)
      |> Enum.with_index()
      |> Enum.map(fn {{point, value}, index} ->
        date_label = bucket_label(point.start, bucket, :long)
        value_label = if value, do: format.(value), else: gettext("No data")

        %{
          index: index,
          position: 100 * (index + 0.5) / count,
          value: value,
          height: if(value, do: 100 * value / ceiling, else: 0),
          date_label: date_label,
          value_label: value_label,
          title: "#{date_label} · #{value_label}"
        }
      end)

    %{
      id: id,
      label: label,
      points: points,
      empty?: measured == [],
      peak_label: format.(peak),
      first_label: series |> List.first() |> axis_label(bucket),
      last_label: series |> List.last() |> axis_label(bucket)
    }
  end

  defp axis_label(nil, _bucket), do: ""
  defp axis_label(%{start: start}, bucket), do: bucket_label(start, bucket, :short)

  defp bucket_label(start, :hour, :short), do: Calendar.strftime(start, "%H:00")
  defp bucket_label(start, :hour, :long), do: Calendar.strftime(start, "%-d %b · %H:00")
  defp bucket_label(start, :day, :short), do: Calendar.strftime(start, "%-d %b")
  defp bucket_label(start, :day, :long), do: Calendar.strftime(start, "%a %-d %b")
  defp bucket_label(start, :month, :short), do: Calendar.strftime(start, "%b")
  defp bucket_label(start, :month, :long), do: Calendar.strftime(start, "%B %Y")

  defp columns(dimension) do
    experience = [
      column(
        :plays,
        gettext("Plays"),
        gettext("Playback attempts"),
        [:experience, :attempts],
        &format_number/1
      ),
      column(
        :startup,
        gettext("Startup"),
        gettext("Median time until the first frame"),
        [:experience, :startup_p50_ms],
        &duration/1
      ),
      column(
        :rebuffering,
        gettext("Rebuffering"),
        gettext("Share of watch time spent buffering"),
        [:experience, :rebuffer_ratio],
        &percent/1
      ),
      column(
        :failures,
        gettext("Failures"),
        gettext("Share of plays that ended in an error"),
        [:experience, :failure_rate],
        &percent/1
      ),
      column(
        :bitrate,
        gettext("Bitrate"),
        gettext("Average delivered bitrate"),
        [:experience, :avg_bitrate],
        &bitrate/1
      )
    ]

    delivery = [
      column(
        :cache_misses,
        gettext("Cache hits"),
        gettext("Share of cacheable requests served from cache"),
        [:delivery, :cache_hit_ratio],
        &percent/1
      ),
      column(
        :slow_edge,
        gettext("Edge latency"),
        gettext("95th percentile time to first byte"),
        [:delivery, :ttfb_p95_ms],
        &duration/1
      ),
      column(
        :delivery_errors,
        gettext("CDN errors"),
        gettext("Share of delivery requests that failed"),
        [:delivery, :error_rate],
        &percent/1
      )
    ]

    if dimension in [:video, :region], do: experience ++ delivery, else: experience
  end

  defp column(id, label, help, path, format) do
    %{
      id: id,
      label: label,
      help: help,
      value: fn row ->
        case get_in(row, path) do
          nil -> "–"
          value -> format.(value)
        end
      end
    }
  end

  # Column ids that a finding called out, per row key.
  defp flagged(findings, dimension) do
    for %{dimension: ^dimension} = finding <- findings, into: %{} do
      {finding.key,
       Enum.map(finding.symptoms, & &1.metric) ++ Enum.map(finding.causes, & &1.type)}
    end
  end

  defp row_id(""), do: "unknown"
  defp row_id(key), do: String.replace(key, ~r/[^A-Za-z0-9_-]/, "-")

  defp dimension_label(dimension) when is_atom(dimension),
    do: dimension_label(Atom.to_string(dimension))

  defp dimension_label("video"), do: gettext("Video")
  defp dimension_label("device"), do: gettext("Device")
  defp dimension_label("browser"), do: gettext("Browser")
  defp dimension_label("region"), do: gettext("Region")

  defp symptom_text(%{metric: :startup, value: value, baseline: baseline}),
    do:
      gettext("Startup takes %{value} here, against %{baseline} across the space.",
        value: duration(value),
        baseline: duration(baseline)
      )

  defp symptom_text(%{metric: :rebuffering, value: value, baseline: baseline}),
    do:
      gettext(
        "Viewers spend %{value} of their watch time buffering, against %{baseline} across the space.",
        value: percent(value),
        baseline: percent(baseline)
      )

  defp symptom_text(%{metric: :failures, value: value, baseline: baseline}),
    do:
      gettext("%{value} of plays end in an error, against %{baseline} across the space.",
        value: percent(value),
        baseline: percent(baseline)
      )

  defp cause_text(%{type: :cache_misses, value: value, baseline: baseline}),
    do:
      gettext(
        "Only %{value} of its requests are served from cache, against %{baseline} overall, so viewers wait on the origin.",
        value: percent(value),
        baseline: percent(baseline)
      )

  defp cause_text(%{type: :slow_edge, value: value, baseline: baseline}),
    do:
      gettext(
        "The edge needs %{value} to answer its slowest 5% of requests, against %{baseline} overall.",
        value: duration(value),
        baseline: duration(baseline)
      )

  defp cause_text(%{type: :delivery_errors, value: value, baseline: baseline}),
    do:
      gettext("%{value} of its delivery requests fail, against %{baseline} overall.",
        value: percent(value),
        baseline: percent(baseline)
      )

  defp cause_text(%{type: :delivery_healthy}),
    do:
      gettext(
        "Delivery looks healthy for these requests, so the cause is more likely the viewer's connection or the media itself."
      )

  defp cause_text(%{type: :no_delivery_data}),
    do: gettext("No delivery telemetry was received for these requests.")

  defp cause_text(%{type: :client}),
    do:
      gettext(
        "Delivery telemetry is not split by device or browser. Compare the regions and videos these viewers watch to rule out the CDN."
      )

  @doc false
  def duration(nil), do: "–"
  def duration(ms) when ms < 1_000, do: "#{round(ms)} ms"
  def duration(ms) when ms < 10_000, do: "#{format_number(Float.round(ms / 1_000, 1))} s"
  def duration(ms), do: "#{format_number(round(ms / 1_000))} s"

  @doc false
  def percent(nil), do: "–"

  def percent(ratio) do
    value = ratio * 100

    cond do
      value == 0 -> "0%"
      value < 10 or (value > 99 and value < 100) -> "#{format_number(Float.round(value, 1))}%"
      true -> "#{round(value)}%"
    end
  end

  @doc false
  def bitrate(nil), do: "–"
  def bitrate(bps) when bps < 1_000_000, do: "#{round(bps / 1_000)} kbps"
  def bitrate(bps), do: "#{format_number(Float.round(bps / 1_000_000, 1))} Mbps"

  @doc false
  def bytes(bytes) when bytes < 1_000_000, do: "#{round(bytes / 1_000)} kB"
  def bytes(bytes) when bytes < 1_000_000_000, do: "#{round(bytes / 1_000_000)} MB"

  def bytes(bytes) when bytes < 1_000_000_000_000, do: "#{decimal(bytes / 1_000_000_000)} GB"
  def bytes(bytes), do: "#{decimal(bytes / 1_000_000_000_000)} TB"

  defp decimal(value) when value >= 100, do: format_number(round(value))
  defp decimal(value), do: format_number(Float.round(value, 1))

  defp format_number(number), do: Formatter.format_number(number)
end
