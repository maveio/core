defmodule MaveCore.Analytics.Sessions.Query do
  @moduledoc false

  # Keep this expression identical to the inventory projection. A revision
  # describes all event fields, including changes that preserve the row count.
  @fingerprint "cityHash64(timestamp, name, session_id, space_hash, embed_hash, video_time, duration, source_url, component, browser, browser_version, os, os_version, device, device_brand)"
  @buckets 16

  def buckets, do: @buckets
  def version, do: 6

  def inventory do
    """
    SELECT space_hash, modulo(cityHash64(session_id), #{@buckets}) AS bucket,
      count() AS source_rows, toString(sumWithOverflow(#{@fingerprint})) AS fingerprint
    FROM events
    GROUP BY space_hash, bucket
    ORDER BY space_hash, bucket
    """
  end

  def changed_sessions do
    """
    WITH source AS (
      SELECT session_id, count() AS source_rows,
        sumWithOverflow(#{@fingerprint}) AS fingerprint
      FROM events
      WHERE space_hash = {$0:String} AND modulo(cityHash64(session_id), #{@buckets}) = {$1:UInt8}
      GROUP BY session_id
    ), previous AS (
      SELECT session_id, source_rows, fingerprint, future_at FROM analytics_sessions
      WHERE space_hash = {$0:String} AND bucket = {$1:UInt8} AND generation = {$2:UUID}
    )
    SELECT if(source.source_rows = 0, previous.session_id, source.session_id)
    FROM source FULL OUTER JOIN previous ON source.session_id = previous.session_id
    WHERE source.source_rows != previous.source_rows OR source.fingerprint != previous.fingerprint
      OR previous.future_at <= now64(6)
    LIMIT 50001
    SETTINGS max_threads = #{limit(:query_threads, 2)}, max_memory_usage = #{limit(:build_memory_bytes, 1_073_741_824)},
      join_use_nulls = 0, max_execution_time = 60
    """
  end

  def copy_sessions do
    """
    INSERT INTO analytics_sessions
    SELECT space_hash, bucket, {$2:UUID}, session_id, source_rows, fingerprint, events, segments, created_at
    FROM analytics_sessions
    PREWHERE space_hash = {$0:String} AND bucket = {$1:UInt8} AND generation = {$3:UUID}
    WHERE session_id NOT IN {$4:Array(UUID)}
    #{copy_settings()}
    """
  end

  def copy_overview do
    """
    INSERT INTO analytics_session_years
    WITH #{compact_days("days")} AS daily
    SELECT space_hash, bucket, {$2:UUID}, session_id, year, first_at, source_device, source_browser,
      watched, arrayMap(d -> (toDate(d.1), d.2), arrayZip(daily.1, daily.2)), created_at, unique_intervals
    FROM analytics_session_years
    PREWHERE space_hash = {$0:String} AND bucket = {$1:UInt8} AND generation = {$3:UUID}
    WHERE session_id NOT IN {$4:Array(UUID)}
    #{copy_settings()}
    """
  end

  def copy_reports do
    """
    INSERT INTO analytics_session_reports
    SELECT space_hash, bucket, {$2:UUID}, session_id, complete, days
    FROM analytics_session_reports
    PREWHERE space_hash = {$0:String} AND bucket = {$1:UInt8} AND generation = {$3:UUID}
    WHERE session_id NOT IN {$4:Array(UUID)}
    #{copy_settings()}
    """
  end

  def build_reports do
    """
    INSERT INTO analytics_session_reports
    WITH input AS (
      SELECT session_id,
        NOT arrayExists(s -> s.3 > s.2 AND dateDiff('day', toDate(s.2, 'UTC'), toDate(s.3, 'UTC')) > 732, segments) AS complete,
        arrayMap(s -> (s.1,s.2,s.3,s.2,s.3,s.4,s.5,s.6),
          arrayFilter(s -> s.3 > s.2 AND dateDiff('day', toDate(s.2, 'UTC'), toDate(s.3, 'UTC')) <= 732, segments)) AS clipped
      FROM analytics_sessions
      PREWHERE space_hash = {$0:String} AND bucket = {$1:UInt8} AND generation = {$2:UUID}
        AND ({$4:UInt8} = 1 OR session_id IN {$3:Array(UUID)})
    ), expanded AS (
      SELECT session_id, arrayJoin(#{bucket_segments(:day)}) AS p FROM input
    ), daily AS (
      SELECT session_id, p.1 AS embed_hash, toDate(p.2, 'UTC') AS day,
        sum(dateDiff('microsecond',p.2,p.3)) AS watched,
        maxOrNullIf(least(1.0,greatest(0.0,(p.6+(p.7-p.6)*dateDiff('microsecond',p.4,p.3)/dateDiff('microsecond',p.4,p.5))/p.8)),
          isFinite(p.8) AND p.8>0 AND isFinite(p.6) AND isFinite(p.7)) AS completion
      FROM expanded GROUP BY session_id,embed_hash,day
    ), reports AS (
      SELECT session_id, groupArray((embed_hash,day,watched,completion)) AS days
      FROM daily GROUP BY session_id
    )
    SELECT {$0:String},{$1:UInt8},{$2:UUID},input.session_id,toUInt8(input.complete),reports.days
    FROM input LEFT JOIN reports ON input.session_id=reports.session_id
    SETTINGS async_insert = 0, join_use_nulls = 0, max_threads = #{limit(:query_threads, 2)},
      max_memory_usage = #{limit(:build_memory_bytes, 1_073_741_824)},
      max_bytes_before_external_group_by = #{div(limit(:build_memory_bytes, 1_073_741_824), 4)}, max_execution_time = 60
    """
  end

  def report_coverage do
    "SELECT countIf(complete = 0) FROM analytics_session_reports PREWHERE space_hash = {$0:String} AND generation IN {$1:Array(UUID)}"
  end

  def top_videos do
    # Route whole sessions to detail when necessary: splitting a session between
    # compact and detail results could apply the one-second threshold twice.
    detail_condition = """
    complete = 0 OR session_id IN future_sessions OR arrayExists(d ->
      (d.2 = toDate({$2:DateTime64(6)}, 'UTC')
        AND {$2:DateTime64(6)} != toDateTime64(toDate({$2:DateTime64(6)}, 'UTC'), 6, 'UTC'))
      OR (d.2 = toDate({$3:DateTime64(6)}, 'UTC')
        AND {$3:DateTime64(6)} != toDateTime64(toDate({$3:DateTime64(6)}, 'UTC'), 6, 'UTC')), days)
    """

    """
    /* mave_perf:sessions.top_videos */
    WITH future_sessions AS (
      SELECT session_id FROM analytics_sessions
      PREWHERE space_hash = {$0:String} AND generation IN {$1:Array(UUID)}
      WHERE isNotNull(future_at)
    ), detail_sessions AS (
      SELECT session_id FROM analytics_session_reports
      PREWHERE space_hash = {$0:String} AND generation IN {$1:Array(UUID)}
      WHERE #{detail_condition}
    ), compact AS (
      SELECT arrayFilter(d -> d.2 >= toDate({$2:DateTime64(6)}, 'UTC')
        AND d.2 < toDate({$3:DateTime64(6)}, 'UTC'), days) AS selected,
        arrayReduce('sumMap', arrayMap(d -> [d.1], selected),
          arrayMap(d -> [d.3], selected)) AS watched
      FROM analytics_session_reports
      PREWHERE space_hash = {$0:String} AND generation IN {$1:Array(UUID)}
      WHERE NOT (#{detail_condition})
    ), detail AS (
      SELECT arrayFilter(s -> s.3 > s.2 AND s.3 > {$2:DateTime64(6)}
        AND s.2 < {$3:DateTime64(6)}, segments) AS selected,
        arrayReduce('sumMap', arrayMap(s -> [s.1], selected),
          arrayMap(s -> [dateDiff('microsecond', greatest(s.2, {$2:DateTime64(6)}),
            least(s.3, {$3:DateTime64(6)}))], selected)) AS watched
      FROM analytics_sessions
      PREWHERE space_hash = {$0:String} AND generation IN {$1:Array(UUID)}
        AND session_id IN detail_sessions
    ), session_views AS (
      SELECT arrayZip(watched.1, watched.2) AS videos FROM compact
      UNION ALL
      SELECT arrayZip(watched.1, watched.2) AS videos FROM detail
    )
    SELECT video.1, countIf(video.2 >= 1000000) AS views
    FROM session_views ARRAY JOIN videos AS video
    GROUP BY video.1 HAVING views > 0
    ORDER BY views DESC, video.1 ASC LIMIT {$4:UInt32}
    SETTINGS max_threads = #{limit(:query_threads, 2)},
      max_memory_usage = #{limit(:read_memory_bytes, 536_870_912)}, max_execution_time = 15
    """
  end

  def report_range(granularity) when granularity in [:day, :week, :month] do
    range_query(report_pieces(granularity), :series, "analytics_session_reports")
  end

  def live_range(granularity) when granularity in [:day, :week, :month] do
    pieces =
      report_pieces(granularity, true) <>
        "\nUNION ALL\n" <> range_pieces(granularity, :series, true)

    range_query(pieces, :series, "analytics_sessions")
  end

  defp report_pieces(granularity, exclude_future \\ false) do
    key =
      %{
        day: "toString(p.2)",
        week: "toString(toMonday(p.2))",
        month: "toString(toStartOfMonth(p.2))"
      }[granularity]

    filter =
      if exclude_future,
        do: "AND session_id NOT IN (#{future_sessions("isNotNull(future_at)")})",
        else: ""

    """
    SELECT arrayMap(p -> (#{key},p.3,p.4),
      arrayFilter(p -> (empty({$4:Array(String)}) OR p.1 IN {$4:Array(String)})
        AND toDateTime64(p.2,6,'UTC') >= {$2:DateTime64(6)}
        AND toDateTime64(p.2,6,'UTC') < {$3:DateTime64(6)}, days)) AS pieces
    FROM analytics_session_reports
    PREWHERE space_hash = {$0:String} AND generation IN {$1:Array(UUID)}
      #{filter}
    """
  end

  def build do
    """
    /* mave_perf:sessions.build */
    INSERT INTO analytics_sessions
    WITH ordered AS (
      SELECT *, row_number() OVER (
        PARTITION BY embed_hash, session_id ORDER BY timestamp
      ) AS event_order
      FROM events
      PREWHERE space_hash = {$0:String}
        AND modulo(cityHash64(session_id), #{@buckets}) = {$1:UInt8}
        AND ({$4:UInt8} = 1 OR session_id IN {$3:Array(UUID)})
    ), videos AS (
      SELECT session_id, embed_hash, count() AS source_rows,
        sumWithOverflow(#{@fingerprint}) AS fingerprint,
        arraySort(e -> e.1, groupArrayIf(
          (event_order, timestamp, name, toFloat64(video_time), toFloat64(duration),
            device, browser, os, source_url), name IN ('play', 'pause'))) AS ev
      FROM ordered GROUP BY session_id, embed_hash
    ), prepared AS (
      SELECT session_id, source_rows, fingerprint,
        arrayMap(e -> (embed_hash, e.2, e.3, e.4, e.5, e.6, e.7, e.8, e.9), ev) AS events,
        arrayMap(p -> (embed_hash, p.1.2, p.2.2, p.1.4, p.2.4, p.1.5),
          arrayFilter(p -> p.1.3 = 'play' AND p.2.3 = 'pause',
            arrayZip(arrayPopBack(ev), arrayPopFront(ev)))) AS segments
      FROM videos
    )
    SELECT {$0:String}, {$1:UInt8}, {$2:UUID}, session_id,
      sum(source_rows), sumWithOverflow(fingerprint),
      groupArrayArray(events), groupArrayArray(segments), now64(6)
    FROM prepared GROUP BY session_id
    SETTINGS async_insert = 0, max_threads = #{limit(:query_threads, 2)}, max_memory_usage = #{limit(:build_memory_bytes, 1_073_741_824)},
      max_bytes_before_external_group_by = #{div(limit(:build_memory_bytes, 1_073_741_824), 4)}, max_execution_time = 60
    """
  end

  def revision do
    """
    WITH arrayMap(e -> e.2, arrayFilter(e -> e.2 < created_at, events)) AS past_events
    SELECT sum(source_rows), toString(sumWithOverflow(fingerprint)),
      min(future_at),
      maxOrNullIf(arrayMax(past_events), notEmpty(past_events))
    FROM analytics_sessions
    WHERE space_hash = {$0:String} AND bucket = {$1:UInt8} AND generation = {$2:UUID}
    """
  end

  def build_overview do
    """
    /* mave_perf:sessions.build_overview */
    INSERT INTO analytics_session_years
    WITH years AS (
      SELECT *, arrayJoin(arrayDistinct(arrayMap(e -> toYear(e.2, 'UTC'),
        arrayFilter(e -> e.2 < created_at, events)))) AS year
      FROM analytics_sessions
      PREWHERE space_hash = {$0:String} AND bucket = {$1:UInt8} AND generation = {$2:UUID}
        AND ({$4:UInt8} = 1 OR session_id IN {$3:Array(UUID)})
    ), prepared AS (
      SELECT *, arraySort(e -> e.2,
        arrayFilter(e -> toYear(e.2, 'UTC') = year AND e.2 < created_at, events)) AS ev,
        arrayFilter(s -> toYear(s.2, 'UTC') = year AND toYear(s.3, 'UTC') = year AND s.3 < created_at, segments) AS seg
      FROM years
    ), daily_totals AS (
      SELECT *, #{compact_days("arrayMap(s -> (toDate(s.2, 'UTC'), greatest(toInt64(0), dateDiff('millisecond', s.2, s.3))), seg)")} AS daily
      FROM prepared
    )
    SELECT space_hash, bucket, generation, session_id, year, ev[1].2, ev[1].6, ev[1].7,
      arraySum(arrayMap(s -> greatest(toInt64(0), dateDiff('millisecond', s.2, s.3)), seg)),
      arrayMap(d -> (toDate(d.1), d.2), arrayZip(daily.1, daily.2)), created_at,
      arrayDistinct(arrayMap(s -> (toDate(s.2, 'UTC'), toUInt64(greatest(0, floor(s.4))),
        toUInt64(greatest(0, floor(s.4))) + least(toUInt64(3600),
          toUInt64(greatest(0, ceil(s.5) - floor(s.4))),
          toUInt64(greatest(0, intDiv(dateDiff('millisecond', s.2, s.3), 1000))))),
        arrayFilter(s -> dateDiff('millisecond', s.2, s.3) < 3600000
          AND isFinite(s.4) AND isFinite(s.5) AND s.4 >= 0 AND s.5 > s.4, seg)))
    FROM daily_totals
    SETTINGS async_insert = 0, max_threads = #{limit(:query_threads, 2)}, max_memory_usage = #{limit(:read_memory_bytes, 536_870_912)}, max_execution_time = 60
    """
  end

  def overview_at, do: overview_query(detail_metrics())
  def overview, do: overview_query(compact_metrics())

  def live_overview do
    affected = future_sessions("future_at <= {$5:DateTime64(6)}")

    overview_query(
      compact_metrics("AND session_id NOT IN (#{affected})") <>
        "\nUNION ALL\n" <> detail_metrics("AND future_at <= {$5:DateTime64(6)}")
    )
  end

  defp compact_metrics(filter \\ "") do
    """
      SELECT
        toMonth(first_at, 'UTC') AS month,
        nullIf(source_device, '') AS device,
        nullIf(source_browser, '') AS browser,
        watched AS watch_year,
        arraySum(arrayMap(d -> if(d.1 >= toDate({$3:DateTime64(6)}, 'UTC'), d.2, 0), days)) AS watch_month,
        arraySum(arrayMap(d -> if(d.1 = toDate({$4:DateTime64(6)}, 'UTC'), d.2, 0), days)) AS watch_today
      FROM analytics_session_years
      PREWHERE space_hash = {$0:String} AND generation IN {$1:Array(UUID)}
      WHERE year = toYear({$2:DateTime64(6)}, 'UTC')
        #{filter}
    """
  end

  defp detail_metrics(filter \\ "") do
    """
    SELECT month, device, browser, watch_year, watch_month, watch_today
    FROM (
      SELECT
        arrayFilter(e -> e.2 >= {$2:DateTime64(6)} AND e.2 < {$5:DateTime64(6)}, events) AS ev,
        arrayFilter(s -> s.2 >= {$2:DateTime64(6)} AND s.3 < {$5:DateTime64(6)}, segments) AS seg,
        arraySort(e -> e.2, ev)[1] AS first,
        toMonth(first.2) AS month,
        nullIf(first.6, '') AS device,
        nullIf(first.7, '') AS browser,
        arraySum(arrayMap(s -> greatest(toInt64(0), dateDiff('millisecond', s.2, s.3)), seg)) AS watch_year,
        arraySum(arrayMap(s -> if(s.2 >= {$3:DateTime64(6)}, greatest(toInt64(0), dateDiff('millisecond', s.2, s.3)), 0), seg)) AS watch_month,
        arraySum(arrayMap(s -> if(s.2 >= {$4:DateTime64(6)}, greatest(toInt64(0), dateDiff('millisecond', s.2, s.3)), 0), seg)) AS watch_today
      FROM analytics_sessions
      PREWHERE space_hash = {$0:String} AND generation IN {$1:Array(UUID)}
        #{filter}
      WHERE notEmpty(ev)
    )
    """
  end

  defp overview_query(metrics) do
    """
    /* mave_perf:sessions.overview */
    WITH metrics AS (
      #{metrics}
    )
    SELECT kind, bucket_month, dimension, views, views_today, views_month,
      total_watch_today, total_watch_month, total_watch_year
    FROM (
      SELECT multiIf(grouping(month) = 0, 'month', grouping(device) = 0, 'device',
          grouping(browser) = 0, 'browser', 'total') AS kind,
        if(grouping(month) = 0, toNullable(month), NULL) AS bucket_month,
        multiIf(grouping(device) = 0, device, grouping(browser) = 0, browser, NULL) AS dimension,
        countIf(watch_year >= 1000) AS views,
        countIf(watch_today >= 1000) AS views_today,
        countIf(watch_month >= 1000) AS views_month,
        sum(watch_today) AS total_watch_today, sum(watch_month) AS total_watch_month, sum(watch_year) AS total_watch_year
      FROM metrics
      GROUP BY GROUPING SETS ((), (month), (device), (browser))
    )
    QUALIFY kind IN ('total', 'month') OR
      row_number() OVER (PARTITION BY kind ORDER BY views DESC, dimension ASC) <= 50
    SETTINGS max_threads = #{limit(:query_threads, 2)}, max_memory_usage = #{limit(:read_memory_bytes, 536_870_912)}, max_execution_time = 10
    """
  end

  def unique_overview do
    compact_unique_query("""
      SELECT unique_intervals AS iv FROM analytics_session_years
      PREWHERE space_hash = {$0:String} AND generation IN {$1:Array(UUID)}
      WHERE year = toYear({$2:DateTime64(6)}, 'UTC')
    """)
  end

  def live_unique_overview do
    affected = future_sessions("future_at <= {$5:DateTime64(6)}")

    compact_unique_query("""
    SELECT unique_intervals AS iv FROM analytics_session_years
    PREWHERE space_hash = {$0:String} AND generation IN {$1:Array(UUID)}
    WHERE year = toYear({$2:DateTime64(6)}, 'UTC') AND session_id NOT IN (#{affected})
    UNION ALL
    SELECT arrayMap(s -> (toDate(s.2, 'UTC'), toUInt64(greatest(0, floor(s.4))),
      toUInt64(greatest(0, floor(s.4))) + least(toUInt64(3600),
        toUInt64(greatest(0, ceil(s.5) - floor(s.4))),
        toUInt64(greatest(0, intDiv(dateDiff('millisecond', s.2, s.3), 1000))))),
      arrayFilter(s -> s.2 >= {$2:DateTime64(6)} AND s.3 < {$5:DateTime64(6)}
        AND dateDiff('millisecond', s.2, s.3) < 3600000
        AND isFinite(s.4) AND isFinite(s.5) AND s.4 >= 0 AND s.5 > s.4, segments)) AS iv
    FROM analytics_sessions
    PREWHERE space_hash = {$0:String} AND generation IN {$1:Array(UUID)}
      AND future_at <= {$5:DateTime64(6)}
    """)
  end

  defp compact_unique_query(intervals) do
    """
    WITH intervals AS (
      #{intervals}

    ), lengths AS (
      SELECT arrayReduce('intervalLengthSum', arrayMap(i -> i.2, iv), arrayMap(i -> i.3, iv)) AS year,
        arrayReduce('intervalLengthSum',
          arrayMap(i -> i.2, arrayFilter(i -> i.1 < toDate({$3:DateTime64(6)}, 'UTC'), iv)),
          arrayMap(i -> i.3, arrayFilter(i -> i.1 < toDate({$3:DateTime64(6)}, 'UTC'), iv))) AS before_month,
        arrayReduce('intervalLengthSum',
          arrayMap(i -> i.2, arrayFilter(i -> i.1 < toDate({$4:DateTime64(6)}, 'UTC'), iv)),
          arrayMap(i -> i.3, arrayFilter(i -> i.1 < toDate({$4:DateTime64(6)}, 'UTC'), iv))) AS before_today
      FROM intervals
    )
    SELECT sum(year - before_today) * 1000, sum(year - before_month) * 1000, sum(year) * 1000
    FROM lengths
    SETTINGS max_threads = #{limit(:query_threads, 2)}, max_memory_usage = #{limit(:read_memory_bytes, 536_870_912)}, max_execution_time = 15
    """
  end

  # Union half-open integer intervals instead of expanding each watched second.
  # Subtract the pre-period union to retain the legacy earliest-watch semantics.
  def unique_watch_time do
    """
    /* mave_perf:sessions.unique_watch_time */
    WITH prepared AS (
      SELECT arrayFilter(s -> s.2 >= {$2:DateTime64(6)} AND s.3 < {$5:DateTime64(6)}
        AND dateDiff('millisecond', s.2, s.3) < 3600000
        AND isFinite(s.4) AND isFinite(s.5) AND s.4 >= 0 AND s.5 > s.4, segments) AS seg
      FROM analytics_sessions
      PREWHERE space_hash = {$0:String} AND generation IN {$1:Array(UUID)}
    ), intervals AS (
      SELECT arrayMap(s -> (s.2, toUInt64(greatest(0, floor(s.4))),
        toUInt64(greatest(0, floor(s.4))) + least(toUInt64(3600),
          toUInt64(greatest(0, ceil(s.5) - floor(s.4))),
          toUInt64(greatest(0, intDiv(dateDiff('millisecond', s.2, s.3), 1000))))), seg) AS iv
      FROM prepared
    ), lengths AS (
      SELECT arrayReduce('intervalLengthSum', arrayMap(i -> i.2, iv), arrayMap(i -> i.3, iv)) AS year,
        arrayReduce('intervalLengthSum',
          arrayMap(i -> i.2, arrayFilter(i -> i.1 < {$3:DateTime64(6)}, iv)),
          arrayMap(i -> i.3, arrayFilter(i -> i.1 < {$3:DateTime64(6)}, iv))) AS before_month,
        arrayReduce('intervalLengthSum',
          arrayMap(i -> i.2, arrayFilter(i -> i.1 < {$4:DateTime64(6)}, iv)),
          arrayMap(i -> i.3, arrayFilter(i -> i.1 < {$4:DateTime64(6)}, iv))) AS before_today
      FROM intervals
    )
    SELECT sum(year - before_today) * 1000, sum(year - before_month) * 1000, sum(year) * 1000
    FROM lengths
    SETTINGS max_threads = #{limit(:query_threads, 2)}, max_memory_usage = #{limit(:read_memory_bytes, 536_870_912)}, max_execution_time = 15
    """
  end

  def stored_spaces do
    """
    SELECT space_hash FROM analytics_sessions GROUP BY space_hash
    UNION DISTINCT
    SELECT space_hash FROM analytics_session_years GROUP BY space_hash
    UNION DISTINCT
    SELECT space_hash FROM analytics_session_reports GROUP BY space_hash
    UNION DISTINCT
    SELECT space_hash FROM analytics_overview_days GROUP BY space_hash
    UNION DISTINCT
    SELECT space_hash FROM analytics_overview_views GROUP BY space_hash
    UNION DISTINCT
    SELECT space_hash FROM analytics_breakdown_days GROUP BY space_hash
    UNION DISTINCT
    SELECT space_hash FROM analytics_breakdown_views GROUP BY space_hash
    """
  end

  def stored_generations do
    """
    SELECT toString(generation) FROM analytics_sessions
    WHERE space_hash = {$0:String} GROUP BY generation
    UNION DISTINCT
    SELECT toString(generation) FROM analytics_session_years
    WHERE space_hash = {$0:String} GROUP BY generation
    UNION DISTINCT
    SELECT toString(generation) FROM analytics_session_reports
    WHERE space_hash = {$0:String} GROUP BY generation
    UNION DISTINCT
    SELECT toString(generation) FROM analytics_overview_days
    WHERE space_hash = {$0:String} GROUP BY generation
    UNION DISTINCT
    SELECT toString(generation) FROM analytics_overview_views
    WHERE space_hash = {$0:String} GROUP BY generation
    UNION DISTINCT
    SELECT toString(generation) FROM analytics_breakdown_days
    WHERE space_hash = {$0:String} GROUP BY generation
    UNION DISTINCT
    SELECT toString(generation) FROM analytics_breakdown_views
    WHERE space_hash = {$0:String} GROUP BY generation
    """
  end

  def cleanup do
    "ALTER TABLE analytics_sessions DROP PARTITION ({$0:String}, {$1:UUID})"
  end

  def cleanup_reports do
    "ALTER TABLE analytics_session_reports DROP PARTITION ({$0:String}, {$1:UUID})"
  end

  def cleanup_overview do
    "ALTER TABLE analytics_session_years DROP PARTITION ({$0:String}, {$1:UUID})"
  end

  def monthly_watch_time do
    """
    /* mave_perf:sessions.monthly_watch_time */
    SELECT sum(arraySum(arrayMap(s -> greatest(toInt64(0), dateDiff('millisecond', s.2, s.3)),
      arrayFilter(s -> s.2 >= {$2:DateTime64(6)} AND s.3 < {$3:DateTime64(6)}, segments))))
    FROM analytics_sessions
    PREWHERE space_hash = {$0:String} AND generation IN {$1:Array(UUID)}
    SETTINGS max_threads = #{limit(:query_threads, 2)}, max_memory_usage = #{limit(:read_memory_bytes, 268_435_456)}, max_execution_time = 5
    """
  end

  def range(granularity, mode)
      when granularity in [:day, :week, :month] and mode in [:series, :videos] do
    range_query(range_pieces(granularity, mode), mode, "analytics_sessions")
  end

  defp range_pieces(granularity, mode, only_future \\ false) do
    bucket =
      %{
        day: "toDate(p.2, 'UTC')",
        week: "toMonday(toDate(p.2, 'UTC'))",
        month: "toStartOfMonth(toDate(p.2, 'UTC'))"
      }[granularity]

    key = if mode == :series, do: "toString(#{bucket})", else: "p.1"
    rows = if mode == :series, do: bucket_segments(granularity), else: "clipped"

    completion_at =
      if mode == :series,
        do:
          "if(p.7 < p.6, least(p.3, toDateTime64(addDays(toDate(p.2, 'UTC'), 1), 6, 'UTC')), p.3)",
        else: "p.3"

    filter = if only_future, do: "AND isNotNull(future_at)", else: ""

    """
      SELECT arrayMap(p -> (#{key}, dateDiff('microsecond', p.2, p.3),
        if(isFinite(p.8) AND p.8 > 0 AND isFinite(p.6) AND isFinite(p.7),
          least(1.0, greatest(0.0, (p.6 + (p.7 - p.6) * dateDiff('microsecond', p.4, #{completion_at})
            / dateDiff('microsecond', p.4, p.5)) / p.8)), NULL)), #{rows}) AS pieces
      FROM (
      SELECT arrayMap(s -> (s.1, greatest(s.2, {$2:DateTime64(6)}), least(s.3, {$3:DateTime64(6)}),
        s.2, s.3, s.4, s.5, s.6),
        arrayFilter(s -> (empty({$4:Array(String)}) OR s.1 IN {$4:Array(String)})
          AND s.3 > {$2:DateTime64(6)} AND s.2 < {$3:DateTime64(6)} AND s.3 > s.2, segments)) AS clipped
      FROM analytics_sessions
      PREWHERE space_hash = {$0:String} AND generation IN {$1:Array(UUID)}
        #{filter}
      ) AS filtered WHERE notEmpty(clipped)
    """
  end

  defp range_query(pieces, mode, table) do
    """
    /* mave_perf:sessions.range */
    WITH pieces AS (
      #{pieces}
    )
    #{range_aggregation(mode, table)}
    """
  end

  defp range_aggregation(mode, table) do
    keys =
      if mode == :series,
        do: "arrayConcat([''], arrayDistinct(arrayMap(p -> p.1, pieces)))",
        else: "arrayDistinct(arrayMap(p -> p.1, pieces))"

    matches = if mode == :series, do: "key = '' OR p.1 = key", else: "p.1 = key"
    single_bucket_keys = if mode == :series, do: 2, else: 1

    source =
      if mode == :series do
        "(SELECT metrics FROM session_metrics UNION ALL SELECT [('', toInt64(0), CAST(NULL, 'Nullable(Float64)'))] AS metrics FROM (SELECT 1 FROM #{table} PREWHERE space_hash = {$0:String} AND generation IN {$1:Array(UUID)} LIMIT 1))"
      else
        "session_metrics"
      end

    """
    , grouped AS (
      SELECT pieces, #{keys} AS keys,
        arraySum(arrayMap(p -> p.2, pieces)) AS total_watched,
        arrayReduce('maxOrNull', arrayMap(p -> p.3, pieces)) AS total_completion
      FROM pieces
    ), session_metrics AS (
      SELECT if(length(keys) <= #{single_bucket_keys},
        arrayMap(key -> (key, total_watched, total_completion), keys),
        arrayMap((key, selected) -> (key,
          arraySum(arrayMap(p -> p.2, selected)),
          arrayReduce('maxOrNull', arrayMap(p -> p.3, selected))),
          keys, arrayMap(key -> arrayFilter(p -> #{matches}, pieces), keys))) AS metrics
      FROM grouped
    )
    SELECT metric.1, countIf(metric.2 >= 1000000), sum(metric.2) / 1000000.0,
      avgOrNullIf(metric.3, metric.2 >= 1000000 AND isNotNull(metric.3))
    FROM #{source} ARRAY JOIN metrics AS metric
    GROUP BY metric.1
    SETTINGS max_threads = #{limit(:query_threads, 2)},
      max_memory_usage = #{limit(:read_memory_bytes, 536_870_912)}, max_execution_time = 15,
      short_circuit_function_evaluation = 'force_enable'
    """
  end

  defp bucket_segments(granularity) do
    {unit, start, finish, add} =
      case granularity do
        :day ->
          {"day", "toDate(s.2, 'UTC')", "toDate(s.3 - INTERVAL 1 MICROSECOND, 'UTC')", "addDays"}

        :week ->
          {"week", "toMonday(toDate(s.2, 'UTC'))",
           "toMonday(toDate(s.3 - INTERVAL 1 MICROSECOND, 'UTC'))", "addWeeks"}

        :month ->
          {"month", "toStartOfMonth(toDate(s.2, 'UTC'))",
           "toStartOfMonth(toDate(s.3 - INTERVAL 1 MICROSECOND, 'UTC'))", "addMonths"}
      end

    """
    arrayConcat(arrayFilter(s -> #{start} = #{finish}, clipped),
      arrayFlatten(arrayMap(s -> arrayMap(offset ->
        (s.1, greatest(s.2, toDateTime64(#{add}(#{start}, offset), 6, 'UTC')),
         least(s.3, toDateTime64(#{add}(#{start}, offset + 1), 6, 'UTC')),
         s.4, s.5, s.6, s.7, s.8),
        range(toUInt32(dateDiff('#{unit}', #{start}, #{finish})) + 1)),
        arrayFilter(s -> #{start} != #{finish}, clipped))))
    """
  end

  defp future_sessions(condition) do
    """
    SELECT session_id FROM analytics_sessions
    PREWHERE space_hash = {$0:String} AND generation IN {$1:Array(UUID)} AND #{condition}
    """
  end

  # Wide event arrays require a byte-sized insert buffer. The default squasher
  # can retain hundreds of megabytes per copy, competing with source merges.
  defp copy_settings do
    """
    SETTINGS async_insert = 0, max_threads = 1, max_insert_threads = 1,
      max_block_size = 512, preferred_block_size_bytes = 2097152,
      min_insert_block_size_rows = 0, min_insert_block_size_bytes = 33554432,
      max_memory_usage = #{min(limit(:build_memory_bytes, 1_073_741_824), 536_870_912)},
      max_execution_time = 60
    """
  end

  # Preserve the original start-day attribution while combining repeated
  # contributions. Dashboard reads need one total per day, not per segment.
  defp compact_days(days) do
    "arrayReduce('sumMap', arrayMap(d -> [toUInt16(d.1)], #{days}), arrayMap(d -> [d.2], #{days}))"
  end

  defp limit(key, default) do
    case Keyword.get(Application.get_env(:mave_core, :analytics_sessions, []) || [], key, default) do
      value when is_integer(value) and value >= 4 -> value
      value when key == :query_threads and is_integer(value) and value > 0 -> value
      _ -> default
    end
  end
end
