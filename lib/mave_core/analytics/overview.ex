defmodule MaveCore.Analytics.Overview do
  @moduledoc """
  Space-wide engagement statistics for the dashboard data page.

  A view is one playback session of one video with at least one second
  watched. Statistics cover a selectable period and are compared with the
  same elapsed portion of the previous calendar period. Weeks start on Monday.
  Calendar boundaries and times are in UTC.
  """

  alias Ecto.Adapters.SQL
  alias MaveCore.Analytics.OverviewPrepared
  alias MaveCore.Analytics.Sessions
  alias MaveCore.ClickHouseRepo
  alias MaveCore.SharedStorageSpace

  @periods ~w(today week month year)
  @default_period "month"
  @min_watch_ms 1_000
  @clickhouse_identifier ~r/^[A-Za-z_][A-Za-z0-9_]*$/

  def periods, do: @periods
  def default_period, do: @default_period

  @doc """
  Returns the overview for `period` (one of `periods/0`).

      {:ok,
       %{
         period: "month",
         bucket: :day,
         current: %{views: 120, watch_ms: 3_600_000, avg_watch_ms: 30_000, avg_completion: 0.58},
         previous: %{views: 100, ...},
         series: [%{start: ~U[...], views: 4, watch_ms: 120_000}, ...],
         devices: [%{device: "desktop", views: 80}, ...],
         browsers: [%{browser: "Chrome", views: 60}, ...]
       }}
  """
  def space_overview(space_hash, period, now \\ DateTime.utc_now())

  def space_overview(space_hash, period, now) when is_binary(space_hash) and period in @periods do
    window = window(period, now)

    with {:ok, space_hash} <- parse_space_hash(space_hash) do
      if SharedStorageSpace.hash?(space_hash) do
        {:ok, empty(period, now)}
      else
        query_overview(space_hash, period, window)
      end
    end
  end

  def space_overview(_space_hash, _period, _now), do: {:error, :invalid_request}

  @doc false
  def window(period, %DateTime{} = now) do
    now = DateTime.truncate(now, :second)

    {bucket, from, until, previous_from} = calendar_period(period, now)
    previous_to = comparison_end(period, now, from, previous_from)

    %{
      bucket: bucket,
      from: from,
      to: now,
      previous_from: previous_from,
      previous_to: previous_to,
      buckets: buckets(bucket, from, DateTime.add(until, -1, :second))
    }
  end

  defp calendar_period("today", now) do
    from = start_of(now, :day)
    {:hour, from, DateTime.add(from, 1, :day), DateTime.add(from, -1, :day)}
  end

  defp calendar_period("week", now) do
    weekday = Date.day_of_week(DateTime.to_date(now))
    from = DateTime.add(start_of(now, :day), 1 - weekday, :day)
    {:day, from, DateTime.add(from, 7, :day), DateTime.add(from, -7, :day)}
  end

  defp calendar_period("month", now) do
    from = start_of(now, :month)
    {:day, from, shift_months(from, 1), shift_months(from, -1)}
  end

  defp calendar_period("year", now) do
    from = %{start_of(now, :month) | month: 1}
    {:month, from, shift_months(from, 12), shift_months(from, -12)}
  end

  defp comparison_end("year", now, _from, _previous_from), do: previous_year(now)

  defp comparison_end(_period, now, from, previous_from) do
    previous_to = DateTime.add(previous_from, DateTime.diff(now, from))
    if DateTime.compare(previous_to, from) == :gt, do: from, else: previous_to
  end

  defp query_overview(space_hash, period, window) do
    if Sessions.enabled?(space_hash) do
      case Sessions.overview_generations(space_hash) do
        {:ok, generations} ->
          run_overview(OverviewPrepared.views_cte(), period, window, [
            space_hash,
            generations,
            window.previous_from,
            window.to
          ])

        {:empty, _} ->
          {:ok, empty(period, window.to)}

        error ->
          error
      end
    else
      run_overview(views_cte(space_hash, window), period, window, [])
    end
  end

  defp run_overview(cte, period, window, params) do
    sql = """
    /* mave_perf:spaces.overview */
    #{cte}
    SELECT kind,
      multiIf(kind = 'total', if(started_at >= #{datetime_literal(window.from)}, 'current', 'previous'),
        kind = 'series', formatDateTime(toDateTime(#{bucket_sql(window.bucket)}(started_at, 'UTC'), 'UTC'), '%Y-%m-%d %H:%i:%S', 'UTC'),
        kind = 'device', ifNull(device, ''), ifNull(browser, '')) AS key,
      toUInt64(count()) AS views,
      toInt64(if(kind IN ('total', 'series'), sum(watch_ms), 0)) AS watch_ms,
      toFloat64(if(kind = 'total', ifNotFinite(avgIf(completion, video_duration > 0), 0), 0)) AS value
    FROM views
    ARRAY JOIN if(started_at >= #{datetime_literal(window.from)},
      ['total', 'series', 'device', 'browser'], ['total']) AS kind
    WHERE started_at >= #{datetime_literal(window.from)} OR started_at < #{datetime_literal(window.previous_to)}
    GROUP BY kind, key
    ORDER BY kind, views DESC, key
    LIMIT 50 BY kind
    SETTINGS max_threads = 1, max_memory_usage = #{query_limit(:read_memory_bytes, 536_870_912)},
      max_block_size = 512, preferred_block_size_bytes = 524288,
      aggregation_memory_efficient_merge_threads = 1,
      max_bytes_before_external_group_by = 134217728, max_execution_time = 15
    """

    query_clickhouse(
      sql,
      {:error, :analytics_unavailable},
      fn rows ->
        {:ok, build_overview(rows, period, window)}
      end,
      params
    )
  end

  defp query_limit(key, default) do
    case Keyword.get(Application.get_env(:mave_core, :analytics_sessions, []), key, default) do
      value when is_integer(value) and value > 0 -> value
      _ -> default
    end
  end

  # One row per (video, session) with at least one second watched.
  defp views_cte(space_hash, window) do
    """
    WITH ordered AS (
      SELECT
        embed_hash,
        session_id,
        timestamp,
        name,
        video_time,
        duration,
        device,
        browser,
        leadInFrame(timestamp) OVER (
          PARTITION BY embed_hash, session_id
          ORDER BY timestamp
          ROWS BETWEEN UNBOUNDED PRECEDING AND UNBOUNDED FOLLOWING
        ) AS next_ts,
        leadInFrame(name) OVER (
          PARTITION BY embed_hash, session_id
          ORDER BY timestamp
          ROWS BETWEEN UNBOUNDED PRECEDING AND UNBOUNDED FOLLOWING
        ) AS next_name
      FROM #{clickhouse_database_name()}.events
      PREWHERE space_hash = #{string_literal(space_hash)}
        AND timestamp >= #{datetime_literal(window.previous_from)}
        AND timestamp < #{datetime_literal(window.to)}
      WHERE name IN ('play', 'pause')
    ),
    views AS (
      SELECT
        embed_hash,
        session_id,
        min(timestamp) AS started_at,
        sumIf(
          greatest(toInt64(0), toUnixTimestamp64Milli(next_ts) - toUnixTimestamp64Milli(timestamp)),
          name = 'play' AND next_name = 'pause'
        ) AS watch_ms,
        max(duration) AS video_duration,
        max(video_time) AS furthest,
        if(video_duration > 0, least(1, furthest / video_duration), 0) AS completion,
        nullIf(argMin(device, timestamp), '') AS device,
        nullIf(argMin(browser, timestamp), '') AS browser
      FROM ordered
      GROUP BY embed_hash, session_id
      HAVING watch_ms >= #{@min_watch_ms}
    )
    """
  end

  defp build_overview(rows, period, window) do
    grouped = Enum.group_by(rows, &hd/1, &tl/1)

    totals =
      Map.new(Map.get(grouped, "total", []), fn [key | values] -> {key, totals(values)} end)

    series =
      Map.new(Map.get(grouped, "series", []), fn [key, views, watch_ms, _] ->
        {key, {views, watch_ms}}
      end)

    %{
      period: period,
      bucket: window.bucket,
      current: Map.get(totals, "current", totals([0, 0, 0.0])),
      previous: Map.get(totals, "previous", totals([0, 0, 0.0])),
      series:
        Enum.map(window.buckets, fn start ->
          {views, watch_ms} = Map.get(series, bucket_key(start), {0, 0})
          %{start: start, views: to_int(views), watch_ms: to_int(watch_ms)}
        end),
      devices: dimension_rows(grouped, "device", :device),
      browsers: dimension_rows(grouped, "browser", :browser)
    }
  end

  defp totals([views, watch_ms, completion]) do
    views = to_int(views)
    watch_ms = to_int(watch_ms)

    %{
      views: views,
      watch_ms: watch_ms,
      avg_watch_ms: if(views > 0, do: div(watch_ms, views), else: 0),
      avg_completion: to_float(completion)
    }
  end

  defp dimension_rows(grouped, kind, field) do
    grouped
    |> Map.get(kind, [])
    |> Enum.map(fn [key, views, _watch_ms, _value] ->
      %{field => if(key in [nil, ""], do: "Unknown", else: key), views: to_int(views)}
    end)
    |> Enum.sort_by(& &1.views, :desc)
  end

  @doc "An overview without views, for spaces that cannot view statistics."
  def empty(period, now \\ DateTime.utc_now()) when period in @periods do
    window = window(period, now)

    %{
      period: period,
      bucket: window.bucket,
      current: totals([0, 0, 0.0]),
      previous: totals([0, 0, 0.0]),
      series: Enum.map(window.buckets, &%{start: &1, views: 0, watch_ms: 0}),
      devices: [],
      browsers: []
    }
  end

  defp buckets(bucket, from, to) do
    from
    |> Stream.iterate(&next_bucket(&1, bucket))
    |> Enum.take_while(&(DateTime.compare(&1, to) != :gt))
  end

  defp next_bucket(start, :hour), do: DateTime.add(start, 1, :hour)
  defp next_bucket(start, :day), do: DateTime.add(start, 1, :day)
  defp next_bucket(start, :month), do: shift_months(start, 1)

  defp start_of(%DateTime{} = dt, :hour), do: %{dt | minute: 0, second: 0, microsecond: {0, 0}}
  defp start_of(%DateTime{} = dt, :day), do: %{start_of(dt, :hour) | hour: 0}
  defp start_of(%DateTime{} = dt, :month), do: %{start_of(dt, :day) | day: 1}

  defp previous_year(%DateTime{} = at) do
    year = at.year - 1
    %{at | year: year, day: min(at.day, Calendar.ISO.days_in_month(year, at.month))}
  end

  defp shift_months(%DateTime{year: year, month: month} = dt, months) do
    index = year * 12 + month - 1 + months
    %{dt | year: div(index, 12), month: rem(index, 12) + 1}
  end

  defp bucket_sql(:hour), do: "toStartOfHour"
  defp bucket_sql(:day), do: "toStartOfDay"
  defp bucket_sql(:month), do: "toStartOfMonth"

  # Matches the formatted bucket start returned by ClickHouse.
  defp bucket_key(%DateTime{} = start) do
    start |> DateTime.to_naive() |> NaiveDateTime.to_string()
  end

  defp parse_space_hash(space_hash) do
    space_hash = String.trim(space_hash)

    if String.match?(space_hash, ~r/^[A-Za-z0-9]{5}$/),
      do: {:ok, space_hash},
      else: {:error, :invalid_space_hash}
  end

  defp to_int(nil), do: 0
  defp to_int(v) when is_integer(v), do: v
  defp to_int(v) when is_float(v), do: trunc(v)
  defp to_int(%Decimal{} = v), do: Decimal.to_integer(v)

  defp to_int(v) when is_binary(v) do
    case Integer.parse(v) do
      {i, _} -> i
      _ -> 0
    end
  end

  defp to_float(v) when is_float(v), do: v
  defp to_float(v) when is_integer(v), do: v * 1.0
  defp to_float(%Decimal{} = v), do: Decimal.to_float(v)
  defp to_float(_v), do: 0.0

  defp clickhouse_database_name do
    case ClickHouseRepo.config()[:database] || "mave_metrics" do
      db_name when is_binary(db_name) ->
        if db_name =~ @clickhouse_identifier, do: db_name, else: "mave_metrics"

      _ ->
        "mave_metrics"
    end
  end

  # sobelow_skip ["SQL.Query"]
  defp query_clickhouse(sql, default, mapper, params) do
    case SQL.query(ClickHouseRepo, sql, params, timeout: 20_000) do
      {:ok, %{rows: rows}} -> mapper.(rows)
      _ -> default
    end
  end

  defp datetime_literal(dt) do
    "parseDateTime64BestEffort(#{string_literal(DateTime.to_iso8601(dt))})"
  end

  defp string_literal(value) do
    escaped =
      value
      |> to_string()
      |> String.replace("\\", "\\\\")
      |> String.replace("'", "\\'")

    "'#{escaped}'"
  end
end
