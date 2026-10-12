defmodule MaveCore.Analytics.Overview do
  @moduledoc """
  Space-wide engagement statistics for the dashboard data page.

  A view is one playback session of one video with at least one second
  watched. Statistics cover a selectable period and are compared with the
  period of equal length right before it. Times are in UTC.
  """

  alias Ecto.Adapters.SQL
  alias MaveCore.ClickHouseRepo
  alias MaveCore.SharedStorageSpace

  @periods ~w(24h 7d 30d 12m)
  @default_period "30d"
  @min_watch_ms 1_000
  @reach_percents [0, 25, 50, 75, 95]
  @clickhouse_identifier ~r/^[A-Za-z_][A-Za-z0-9_]*$/

  def periods, do: @periods
  def default_period, do: @default_period

  @doc """
  Returns the overview for `period` (one of `periods/0`).

      {:ok,
       %{
         period: "30d",
         bucket: :day,
         current: %{views: 120, watch_ms: 3_600_000, avg_watch_ms: 30_000, avg_completion: 0.58},
         previous: %{views: 100, ...},
         series: [%{start: ~U[...], views: 4, watch_ms: 120_000}, ...],
         devices: [%{device: "desktop", views: 80}, ...],
         browsers: [%{browser: "Chrome", views: 60}, ...],
         operating_systems: [%{os: "Mac OS", views: 50}, ...],
         websites: [%{website: "example.com", views: 70}, ...],
         reach: [%{percent: 0, share: 1.0}, %{percent: 25, share: 0.8}, ...],
         hours: %{{1, 9} => 12, ...}
       }}

  `reach` is the share of views that got at least that far into the video;
  95% counts as finished. `hours` maps `{weekday, hour}` (Monday is 1) to
  views started in that hour.
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

    {bucket, from} =
      case period do
        "24h" -> {:hour, now |> start_of(:hour) |> DateTime.add(-23, :hour)}
        "7d" -> {:day, now |> start_of(:day) |> DateTime.add(-6, :day)}
        "30d" -> {:day, now |> start_of(:day) |> DateTime.add(-29, :day)}
        "12m" -> {:month, now |> start_of(:month) |> shift_months(-11)}
      end

    length = DateTime.diff(now, from)

    %{
      bucket: bucket,
      from: from,
      to: now,
      previous_from: DateTime.add(from, -length),
      buckets: buckets(bucket, from, now)
    }
  end

  defp query_overview(space_hash, period, window) do
    sql = """
    /* mave_perf:spaces.overview */
    #{views_cte(space_hash, window)}
    SELECT
      'total' AS kind,
      if(started_at >= #{datetime_literal(window.from)}, 'current', 'previous') AS key,
      toUInt64(count()) AS views,
      toInt64(sum(watch_ms)) AS watch_ms,
      toFloat64(ifNotFinite(avgIf(completion, video_duration > 0), 0)) AS value
    FROM views
    GROUP BY key
    UNION ALL
    SELECT
      'series' AS kind,
      formatDateTime(toDateTime(#{bucket_sql(window.bucket)}(started_at, 'UTC'), 'UTC'), '%Y-%m-%d %H:%i:%S', 'UTC') AS key,
      toUInt64(count()) AS views,
      toInt64(sum(watch_ms)) AS watch_ms,
      toFloat64(0) AS value
    FROM views
    WHERE started_at >= #{datetime_literal(window.from)}
    GROUP BY key
    UNION ALL
    #{dimension_sql("device", "device", window)}
    UNION ALL
    #{dimension_sql("browser", "browser", window)}
    UNION ALL
    #{dimension_sql("os", "os", window)}
    UNION ALL
    #{dimension_sql("website", "website", window)}
    UNION ALL
    SELECT
      'reach' AS kind,
      toString(percent) AS key,
      toUInt64(countIf(completion * 100 >= percent)) AS views,
      toInt64(0) AS watch_ms,
      toFloat64(0) AS value
    FROM views
    ARRAY JOIN #{reach_sql()} AS percent
    WHERE started_at >= #{datetime_literal(window.from)} AND video_duration > 0
    GROUP BY percent
    UNION ALL
    SELECT
      'hour' AS kind,
      concat(toString(toDayOfWeek(started_at, 0, 'UTC')), '-', toString(toHour(started_at, 'UTC'))) AS key,
      toUInt64(count()) AS views,
      toInt64(0) AS watch_ms,
      toFloat64(0) AS value
    FROM views
    WHERE started_at >= #{datetime_literal(window.from)}
    GROUP BY key
    """

    query_clickhouse(sql, {:error, :analytics_unavailable}, fn rows ->
      {:ok, build_overview(rows, period, window)}
    end)
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
        os,
        source_url,
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
        nullIf(lower(argMin(device, timestamp)), '') AS device,
        nullIf(argMin(browser, timestamp), '') AS browser,
        nullIf(argMin(os, timestamp), '') AS os,
        nullIf(domainWithoutWWW(argMin(source_url, timestamp)), '') AS website
      FROM ordered
      GROUP BY embed_hash, session_id
      HAVING watch_ms >= #{@min_watch_ms}
    )
    """
  end

  defp dimension_sql(kind, column, window) do
    """
    SELECT
      #{string_literal(kind)} AS kind,
      ifNull(#{column}, '') AS key,
      toUInt64(count()) AS views,
      toInt64(0) AS watch_ms,
      toFloat64(0) AS value
    FROM views
    WHERE started_at >= #{datetime_literal(window.from)}
    GROUP BY key
    ORDER BY views DESC
    LIMIT 50
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
      browsers: dimension_rows(grouped, "browser", :browser),
      operating_systems: dimension_rows(grouped, "os", :os),
      websites: dimension_rows(grouped, "website", :website),
      reach: reach(Map.get(grouped, "reach", [])),
      hours: hours(Map.get(grouped, "hour", []))
    }
  end

  defp reach(rows) do
    counts = Map.new(rows, fn [percent, views, _watch_ms, _value] -> {percent, to_int(views)} end)
    started = Map.get(counts, "0", 0)

    Enum.map(@reach_percents, fn percent ->
      views = Map.get(counts, Integer.to_string(percent), 0)
      %{percent: percent, share: if(started > 0, do: views / started, else: 0.0)}
    end)
  end

  defp hours(rows) do
    Map.new(rows, fn [key, views, _watch_ms, _value] ->
      [weekday, hour] = key |> String.split("-") |> Enum.map(&String.to_integer/1)
      {{weekday, hour}, to_int(views)}
    end)
  end

  defp reach_sql, do: "[" <> Enum.map_join(@reach_percents, ", ", &Integer.to_string/1) <> "]"

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
      browsers: [],
      operating_systems: [],
      websites: [],
      reach: Enum.map(@reach_percents, &%{percent: &1, share: 0.0}),
      hours: %{}
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
  defp query_clickhouse(sql, default, mapper) do
    case SQL.query(ClickHouseRepo, sql, []) do
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
