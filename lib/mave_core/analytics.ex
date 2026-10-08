defmodule MaveCore.Analytics do
  @moduledoc false

  alias Ecto.Adapters.SQL
  alias MaveCore.ClickHouseRepo
  alias MaveCore.SharedStorageSpace

  @clickhouse_identifier ~r/^[A-Za-z_][A-Za-z0-9_]*$/
  @min_watch_seconds 1
  @max_unique_watch_segment_seconds 60 * 60
  @sidebar_query_timeout 5_000

  def space_data(space_hash) when is_binary(space_hash) do
    with {:ok, space_hash} <- parse_space_hash(space_hash) do
      if SharedStorageSpace.hash?(space_hash) do
        {:ok, empty_space_data(space_hash)}
      else
        do_space_data(space_hash)
      end
    end
  end

  def space_data(_), do: {:error, :invalid_space_hash}

  defp do_space_data(space_hash) do
    now = DateTime.utc_now()

    today_from = DateTime.new!(DateTime.to_date(now), ~T[00:00:00], "Etc/UTC")
    month_from = DateTime.new!(Date.new!(now.year, now.month, 1), ~T[00:00:00], "Etc/UTC")
    year_from = DateTime.new!(Date.new!(now.year, 1, 1), ~T[00:00:00], "Etc/UTC")

    db_name = clickhouse_database_name()
    today_from_lit = datetime_literal(today_from)
    month_from_lit = datetime_literal(month_from)
    year_from_lit = datetime_literal(year_from)
    to_lit = datetime_literal(now)
    threshold = @min_watch_seconds * 1000

    main_metrics_task =
      Task.async(fn ->
        get_main_metrics(
          db_name,
          space_hash,
          today_from_lit,
          month_from_lit,
          year_from_lit,
          to_lit,
          threshold
        )
      end)

    unique_watch_time_task =
      Task.async(fn ->
        get_all_unique_watch_times(
          db_name,
          space_hash,
          today_from_lit,
          month_from_lit,
          year_from_lit,
          to_lit
        )
      end)

    dimensions_task =
      Task.async(fn ->
        get_dimensions(db_name, space_hash, year_from_lit, to_lit, threshold)
      end)

    %{views: views, watch_time: watch_time} =
      await_task(main_metrics_task, %{
        views: %{today: 0, month: 0, year: 0},
        watch_time: %{today: 0, month: 0, year: 0}
      })

    %{today: uwt_today, month: uwt_month, year: uwt_year} =
      await_task(unique_watch_time_task, %{today: 0, month: 0, year: 0})

    %{views_by_month: views_by_month, devices: devices, browsers: browsers} =
      await_task(dimensions_task, %{
        views_by_month: empty_months(),
        devices: [],
        browsers: []
      })

    {:ok,
     %{
       id: space_hash,
       views: views,
       watch_time: watch_time,
       unique_watch_time: %{
         today: uwt_today,
         month: uwt_month,
         year: uwt_year
       },
       views_by_month: views_by_month,
       devices: devices,
       browsers: browsers
     }}
  end

  def space_monthly_watch_time(space_hash) when is_binary(space_hash) do
    with {:ok, space_hash} <- parse_space_hash(space_hash) do
      if SharedStorageSpace.hash?(space_hash) do
        {:ok, %{watch_time: %{month: 0}}}
      else
        do_space_monthly_watch_time(space_hash)
      end
    end
  end

  def space_monthly_watch_time(_), do: {:error, :invalid_space_hash}

  defp do_space_monthly_watch_time(space_hash) do
    now = DateTime.utc_now()
    month_from = DateTime.new!(Date.new!(now.year, now.month, 1), ~T[00:00:00], "Etc/UTC")

    db_name = clickhouse_database_name()
    month_from_lit = datetime_literal(month_from)
    to_lit = datetime_literal(now)

    sql = """
    /* mave_perf:spaces.monthly_watch_time */
    WITH ordered AS (
      SELECT
        session_id,
        timestamp,
        name,
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
      FROM #{db_name}.events
      PREWHERE space_hash = #{string_literal(space_hash)}
        AND timestamp >= #{month_from_lit}
        AND timestamp < #{to_lit}
      WHERE name IN ('play', 'pause')
    )
    SELECT
      sumIf(
        greatest(toInt64(0), toUnixTimestamp64Milli(next_ts) - toUnixTimestamp64Milli(timestamp)),
        name = 'play' AND next_name = 'pause'
      ) AS watch_time_month
    FROM ordered
    SETTINGS max_execution_time = 5
    """

    query_clickhouse(
      sql,
      {:ok, %{watch_time: %{month: 0}}},
      fn [[watch_time_month]] ->
        {:ok, %{watch_time: %{month: to_int(watch_time_month)}}}
      end,
      timeout: @sidebar_query_timeout
    )
  end

  defp await_task(task, default) do
    Task.await(task, 60_000)
  catch
    :exit, _ -> default
  end

  defp parse_space_hash(space_hash) when is_binary(space_hash) do
    space_hash = String.trim(space_hash)

    case space_hash do
      <<_::binary-size(5)>> = value ->
        if valid_hash?(value), do: {:ok, value}, else: {:error, :invalid_space_hash}

      _ ->
        {:error, :invalid_space_hash}
    end
  end

  defp valid_hash?(value), do: String.match?(value, ~r/^[A-Za-z0-9]+$/)

  defp get_main_metrics(
         db_name,
         space_hash,
         today_from_lit,
         month_from_lit,
         year_from_lit,
         to_lit,
         threshold
       ) do
    sql = """
    /* mave_perf:spaces.main_metrics */
    WITH ordered AS (
      SELECT
        session_id,
        timestamp,
        name,
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
      FROM #{db_name}.events
      PREWHERE space_hash = #{string_literal(space_hash)}
        AND timestamp >= #{year_from_lit}
        AND timestamp < #{to_lit}
      WHERE name IN ('play', 'pause')
    ),
    session_aggregates AS (
      SELECT
        session_id,
        sumIf(
          greatest(toInt64(0), toUnixTimestamp64Milli(next_ts) - toUnixTimestamp64Milli(timestamp)),
          name = 'play' AND next_name = 'pause' AND timestamp >= #{today_from_lit}
        ) AS watch_ms_today,
        sumIf(
          greatest(toInt64(0), toUnixTimestamp64Milli(next_ts) - toUnixTimestamp64Milli(timestamp)),
          name = 'play' AND next_name = 'pause' AND timestamp >= #{month_from_lit}
        ) AS watch_ms_month,
        sumIf(
          greatest(toInt64(0), toUnixTimestamp64Milli(next_ts) - toUnixTimestamp64Milli(timestamp)),
          name = 'play' AND next_name = 'pause'
        ) AS watch_ms_year
      FROM ordered
      GROUP BY session_id
    )
    SELECT
      countIf(watch_ms_today >= #{threshold}) AS views_today,
      countIf(watch_ms_month >= #{threshold}) AS views_month,
      countIf(watch_ms_year >= #{threshold}) AS views_year,
      sum(watch_ms_today) AS watch_time_today,
      sum(watch_ms_month) AS watch_time_month,
      sum(watch_ms_year) AS watch_time_year
    FROM session_aggregates
    """

    query_clickhouse(
      sql,
      %{views: %{today: 0, month: 0, year: 0}, watch_time: %{today: 0, month: 0, year: 0}},
      fn [[views_today, views_month, views_year, wt_today, wt_month, wt_year]] ->
        %{
          views: %{
            today: to_int(views_today),
            month: to_int(views_month),
            year: to_int(views_year)
          },
          watch_time: %{today: to_int(wt_today), month: to_int(wt_month), year: to_int(wt_year)}
        }
      end
    )
  end

  defp get_all_unique_watch_times(
         db_name,
         space_hash,
         today_from_lit,
         month_from_lit,
         year_from_lit,
         to_lit
       ) do
    sql = """
    /* mave_perf:spaces.unique_watch_time */
    WITH ordered AS (
      SELECT
        session_id,
        timestamp,
        name,
        video_time,
        leadInFrame(timestamp) OVER (
          PARTITION BY embed_hash, session_id
          ORDER BY timestamp
          ROWS BETWEEN UNBOUNDED PRECEDING AND UNBOUNDED FOLLOWING
        ) AS next_ts,
        leadInFrame(name) OVER (
          PARTITION BY embed_hash, session_id
          ORDER BY timestamp
          ROWS BETWEEN UNBOUNDED PRECEDING AND UNBOUNDED FOLLOWING
        ) AS next_name,
        leadInFrame(video_time) OVER (
          PARTITION BY embed_hash, session_id
          ORDER BY timestamp
          ROWS BETWEEN UNBOUNDED PRECEDING AND UNBOUNDED FOLLOWING
        ) AS next_video_time
      FROM #{db_name}.events
      PREWHERE space_hash = #{string_literal(space_hash)}
        AND timestamp >= #{year_from_lit}
        AND timestamp < #{to_lit}
      WHERE name IN ('play', 'pause')
    ),
    bounded_segments AS (
      SELECT
        session_id,
        timestamp,
        toUInt64(greatest(0, floor(video_time))) AS start_second,
        least(
          toUInt32(#{@max_unique_watch_segment_seconds}),
          toUInt32(greatest(0, ceil(next_video_time) - floor(video_time))),
          toUInt32(
            greatest(
              0,
              intDiv(
                toUnixTimestamp64Milli(next_ts) - toUnixTimestamp64Milli(timestamp),
                1000
              )
            )
          )
        ) AS seconds_watched
      FROM ordered
      WHERE name = 'play' AND next_name = 'pause'
        AND toUnixTimestamp64Milli(next_ts) - toUnixTimestamp64Milli(timestamp) < 3600000
        AND isFinite(video_time)
        AND isFinite(next_video_time)
        AND video_time >= 0
        AND next_video_time > video_time
    ),
    exploded_seconds AS (
      SELECT
        session_id,
        timestamp,
        start_second + arrayJoin(range(seconds_watched)) AS second
      FROM bounded_segments
      WHERE seconds_watched > 0
    ),
    unique_seconds AS (
      SELECT
        session_id,
        second,
        min(timestamp) AS ts
      FROM exploded_seconds
      GROUP BY session_id, second
    )
    SELECT
      countIf(ts >= #{today_from_lit}) * 1000 AS uwt_today,
      countIf(ts >= #{month_from_lit}) * 1000 AS uwt_month,
      count() * 1000 AS uwt_year
    FROM unique_seconds
    """

    query_clickhouse(sql, %{today: 0, month: 0, year: 0}, fn [[uwt_today, uwt_month, uwt_year]] ->
      %{today: to_int(uwt_today), month: to_int(uwt_month), year: to_int(uwt_year)}
    end)
  end

  defp get_dimensions(db_name, space_hash, year_from_lit, to_lit, threshold) do
    sql = """
    /* mave_perf:spaces.dimensions */
    WITH ordered AS (
      SELECT
        session_id,
        timestamp,
        name,
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
      FROM #{db_name}.events
      PREWHERE space_hash = #{string_literal(space_hash)}
        AND timestamp >= #{year_from_lit}
        AND timestamp < #{to_lit}
      WHERE name IN ('play', 'pause')
    ),
    session_aggregates AS (
      SELECT
        session_id,
        sumIf(
          greatest(toInt64(0), toUnixTimestamp64Milli(next_ts) - toUnixTimestamp64Milli(timestamp)),
          name = 'play' AND next_name = 'pause'
        ) AS watch_ms_year,
        toUInt8(toMonth(min(timestamp))) AS month,
        nullIf(argMin(device, timestamp), '') AS dimension_device,
        nullIf(argMin(browser, timestamp), '') AS dimension_browser
      FROM ordered
      GROUP BY session_id
    )
    SELECT
      'month' AS kind,
      toNullable(month) AS month,
      CAST(NULL AS Nullable(String)) AS dimension,
      countIf(watch_ms_year >= #{threshold}) AS views
    FROM session_aggregates
    GROUP BY month
    UNION ALL
    SELECT
      'device' AS kind,
      CAST(NULL AS Nullable(UInt8)) AS month,
      dimension_device AS dimension,
      countIf(watch_ms_year >= #{threshold}) AS views
    FROM session_aggregates
    GROUP BY dimension_device
    ORDER BY views DESC
    LIMIT 50
    UNION ALL
    SELECT
      'browser' AS kind,
      CAST(NULL AS Nullable(UInt8)) AS month,
      dimension_browser AS dimension,
      countIf(watch_ms_year >= #{threshold}) AS views
    FROM session_aggregates
    GROUP BY dimension_browser
    ORDER BY views DESC
    LIMIT 50
    """

    query_clickhouse(sql, %{views_by_month: empty_months(), devices: [], browsers: []}, fn rows ->
      {month_map, devices, browsers} =
        Enum.reduce(rows, {%{}, [], []}, fn
          ["month", month, _dimension, views], {month_map, devices, browsers}
          when not is_nil(month) ->
            month_i = to_int(month)
            update_month_views(month_map, devices, browsers, month_i, views)

          ["device", _month, dimension, views], {month_map, devices, browsers} ->
            device = analytics_dimension(dimension)
            {month_map, [%{device: device, views: to_int(views)} | devices], browsers}

          ["browser", _month, dimension, views], {month_map, devices, browsers} ->
            browser = analytics_dimension(dimension)
            {month_map, devices, [%{browser: browser, views: to_int(views)} | browsers]}

          _row, acc ->
            acc
        end)

      %{
        views_by_month:
          Enum.map(1..12, fn month -> %{month: month, views: Map.get(month_map, month, 0)} end),
        devices: Enum.sort_by(devices, & &1.views, :desc),
        browsers: Enum.sort_by(browsers, & &1.views, :desc)
      }
    end)
  end

  defp to_int(nil), do: 0
  defp to_int(v) when is_integer(v), do: v
  defp to_int(%Decimal{} = v), do: Decimal.to_integer(v)

  defp to_int(v) when is_binary(v) do
    case Integer.parse(v) do
      {i, _} -> i
      _ -> 0
    end
  end

  defp to_int(v) when is_float(v), do: trunc(v)

  defp empty_months, do: Enum.map(1..12, fn month -> %{month: month, views: 0} end)

  defp analytics_dimension(dimension) when is_binary(dimension) and dimension != "", do: dimension
  defp analytics_dimension(_dimension), do: "Unknown"

  defp update_month_views(month_map, devices, browsers, month_i, views) when month_i in 1..12 do
    {Map.put(month_map, month_i, to_int(views)), devices, browsers}
  end

  defp update_month_views(month_map, devices, browsers, _month_i, _views) do
    {month_map, devices, browsers}
  end

  defp empty_space_data(space_hash) do
    %{
      id: space_hash,
      views: %{today: 0, month: 0, year: 0},
      watch_time: %{today: 0, month: 0, year: 0},
      unique_watch_time: %{today: 0, month: 0, year: 0},
      views_by_month: empty_months(),
      devices: [],
      browsers: []
    }
  end

  defp clickhouse_database_name do
    case ClickHouseRepo.config()[:database] || "mave_metrics" do
      db_name when is_binary(db_name) ->
        if valid_clickhouse_db_name?(db_name), do: db_name, else: "mave_metrics"

      _ ->
        "mave_metrics"
    end
  end

  # sobelow_skip ["SQL.Query"]
  defp query_clickhouse(sql, default, mapper, opts \\ [])
       when is_binary(sql) and is_function(mapper, 1) do
    case SQL.query(ClickHouseRepo, sql, [], opts) do
      {:ok, %{rows: rows}} -> mapper.(rows)
      _ -> default
    end
  end

  defp datetime_literal(dt) do
    iso = DateTime.to_iso8601(dt)
    "parseDateTime64BestEffort(#{string_literal(iso)})"
  end

  defp valid_clickhouse_db_name?(db_name), do: db_name =~ @clickhouse_identifier

  defp string_literal(value) do
    escaped =
      value
      |> to_string()
      |> String.replace("\\", "\\\\")
      |> String.replace("'", "\\'")

    "'#{escaped}'"
  end
end
