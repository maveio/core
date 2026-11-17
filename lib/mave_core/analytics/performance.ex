defmodule MaveCore.Analytics.Performance do
  @moduledoc """
  Playback reliability and delivery performance for the dashboard data page.

  Two sources are read side by side. Players report what viewers experience
  (`MaveCore.Metrics.PlaybackQuality`): one playback attempt is one session of
  one video. The CDN or edge reports what delivery did
  (`MaveCore.Metrics.CdnRequest`). Both are grouped the same way, so a slow
  video or region can be compared with its cache and latency figures.

  Periods and buckets match `MaveCore.Analytics.Overview`; times are in UTC.
  """

  alias Ecto.Adapters.SQL
  alias MaveCore.Analytics.Overview
  alias MaveCore.ClickHouseRepo
  alias MaveCore.SharedStorageSpace

  @dimensions ~w(video device browser region)a
  @delivery_dimensions ~w(video region)a
  @breakdown_limit 25
  @clickhouse_identifier ~r/^[A-Za-z_][A-Za-z0-9_]*$/

  # A segment needs this much traffic before it is compared with the space.
  @min_attempts 20
  @min_startups 10
  @min_affected 10
  @min_requests 50
  @max_findings 4

  def dimensions, do: @dimensions

  @doc """
  Returns the performance report for `period` (one of `Overview.periods/0`).

      {:ok,
       %{
         period: "week",
         bucket: :day,
         experience: %{attempts: 420, startup_p50_ms: 810, startup_p95_ms: 2900,
           failure_rate: 0.012, startup_failures: 3, playback_failures: 2,
           rebuffer_ratio: 0.004, rebuffered_attempts: 31, avg_bitrate: 3_400_000, ...},
         delivery: %{requests: 51_200, cache_hit_ratio: 0.94, origin_requests: 3_100,
           bytes: 81_000_000_000, origin_bytes: 4_900_000_000, ttfb_p50_ms: 21,
           ttfb_p95_ms: 140, error_rate: 0.002, ...},
         series: [%{start: ~U[...], experience: %{...}, delivery: %{...}}, ...],
         resolutions: [%{height: 1080, share: 0.71}, ...],
         breakdowns: %{video: [%{key: "EMBEDHASH0", experience: %{...}, delivery: %{...}}], ...},
         findings: [%{dimension: :region, key: "DE", symptoms: [...], causes: [...]}]
       }}

  Rates are `nil` when nothing was measured. Only videos and regions carry
  delivery figures; devices and browsers are known to the player alone.
  """
  def report(space_hash, period, now \\ DateTime.utc_now())

  def report(space_hash, period, %DateTime{} = now) when is_binary(space_hash) do
    with true <- period in Overview.periods(),
         space_hash = String.trim(space_hash),
         true <- String.match?(space_hash, ~r/^[A-Za-z0-9]{5}$/) do
      window = Overview.window(period, now)

      if SharedStorageSpace.hash?(space_hash),
        do: {:ok, build(period, window, [], [], [])},
        else: query(space_hash, period, window)
    else
      _ -> {:error, :invalid_request}
    end
  end

  def report(_space_hash, _period, _now), do: {:error, :invalid_request}

  @doc "A report without measurements, for spaces that cannot view statistics."
  def empty(period, now \\ DateTime.utc_now()) do
    build(period, Overview.window(period, now), [], [], [])
  end

  defp query(space_hash, period, window) do
    params = [space_hash, window.from, window.to]

    [experience, delivery, resolutions] =
      [experience_sql(window.bucket), delivery_sql(window.bucket), resolutions_sql()]
      |> Task.async_stream(&run(&1, params), timeout: 25_000, ordered: true)
      |> Enum.map(fn {:ok, result} -> result end)

    with {:ok, experience} <- experience,
         {:ok, delivery} <- delivery,
         {:ok, resolutions} <- resolutions do
      {:ok, build(period, window, experience, delivery, resolutions)}
    end
  end

  # sobelow_skip ["SQL.Query"]
  defp run(sql, params) do
    case SQL.query(ClickHouseRepo, sql, params, timeout: 20_000) do
      {:ok, %{rows: rows}} -> {:ok, rows}
      _ -> {:error, :analytics_unavailable}
    end
  end

  # One row per playback attempt, then every grouping in a single pass.
  defp experience_sql(bucket) do
    """
    /* mave_perf:spaces.performance_experience */
    WITH attempts AS (
      SELECT
        embed_hash,
        session_id,
        min(timestamp) AS started_at,
        countIf(name = 'playback_startup') > 0 AS started,
        minIf(startup_ms, name = 'playback_startup') AS startup,
        countIf(name = 'playback_error') > 0 AS failed,
        countIf(name = 'playback_rebuffer') AS stalls,
        sumIf(rebuffer_ms, name = 'playback_rebuffer') AS stalled_ms,
        sumIf(playing_ms, name = 'playback_sample') AS played_ms,
        sumIf(toUInt64(bitrate) * playing_ms, name = 'playback_sample' AND bitrate > 0) AS bitrate_weight,
        sumIf(playing_ms, name = 'playback_sample' AND bitrate > 0) AS bitrate_ms,
        lower(argMin(device, timestamp)) AS viewer_device,
        argMin(browser, timestamp) AS viewer_browser,
        argMin(country, timestamp) AS viewer_country
      FROM #{database()}.playback_quality
      WHERE space_hash = {$0:String}
        AND timestamp >= {$1:DateTime64(6)} AND timestamp < {$2:DateTime64(6)}
      GROUP BY embed_hash, session_id
    )
    SELECT kind,
      multiIf(kind = 'total', '', kind = 'series', #{bucket_key_sql(bucket, "started_at")},
        kind = 'video', embed_hash, kind = 'device', viewer_device,
        kind = 'browser', viewer_browser, viewer_country) AS key,
      toUInt64(count()) AS attempts,
      toUInt64(countIf(started)) AS startups,
      toFloat64(ifNotFinite(quantileIf(0.5)(startup, started), 0)) AS startup_p50,
      toFloat64(ifNotFinite(quantileIf(0.95)(startup, started), 0)) AS startup_p95,
      toUInt64(countIf(failed AND NOT started)) AS startup_failures,
      toUInt64(countIf(failed AND started)) AS playback_failures,
      toUInt64(sum(stalls)) AS rebuffers,
      toUInt64(countIf(stalls > 0)) AS rebuffered_attempts,
      toUInt64(sum(stalled_ms)) AS rebuffer_ms,
      toUInt64(sum(played_ms)) AS playing_ms,
      toUInt64(sum(bitrate_weight)) AS total_bitrate_weight,
      toUInt64(sum(bitrate_ms)) AS total_bitrate_ms
    FROM attempts
    ARRAY JOIN ['total', 'series', 'video', 'device', 'browser', 'region'] AS kind
    GROUP BY kind, key
    ORDER BY kind, attempts DESC, key
    LIMIT 100 BY kind
    #{settings()}
    """
  end

  defp delivery_sql(bucket) do
    """
    /* mave_perf:spaces.performance_delivery */
    SELECT kind,
      multiIf(kind = 'total', '', kind = 'series', #{bucket_key_sql(bucket, "timestamp")},
        kind = 'video', embed_hash, country) AS key,
      toUInt64(count()) AS requests,
      toUInt64(countIf(cache_status = 'hit')) AS hits,
      toUInt64(countIf(cache_status = 'miss')) AS misses,
      toUInt64(countIf(origin = 1)) AS origin_requests,
      toUInt64(sum(bytes)) AS total_bytes,
      toUInt64(sumIf(bytes, origin = 1)) AS origin_bytes,
      toFloat64(ifNotFinite(quantile(0.5)(ttfb_ms), 0)) AS ttfb_p50,
      toFloat64(ifNotFinite(quantile(0.95)(ttfb_ms), 0)) AS ttfb_p95,
      toUInt64(countIf(status >= 400 AND status < 500)) AS client_errors,
      toUInt64(countIf(status >= 500)) AS server_errors
    FROM #{database()}.cdn_requests
    ARRAY JOIN ['total', 'series', 'video', 'region'] AS kind
    WHERE space_hash = {$0:String}
      AND timestamp >= {$1:DateTime64(6)} AND timestamp < {$2:DateTime64(6)}
    GROUP BY kind, key
    ORDER BY kind, requests DESC, key
    LIMIT 100 BY kind
    #{settings()}
    """
  end

  defp resolutions_sql do
    """
    /* mave_perf:spaces.performance_resolutions */
    SELECT toUInt32(height) AS rendition, toUInt64(sum(playing_ms)) AS played_ms
    FROM #{database()}.playback_quality
    WHERE space_hash = {$0:String}
      AND timestamp >= {$1:DateTime64(6)} AND timestamp < {$2:DateTime64(6)}
      AND name = 'playback_sample' AND height > 0
    GROUP BY rendition
    ORDER BY played_ms DESC, rendition DESC
    LIMIT 6
    #{settings()}
    """
  end

  defp settings do
    "SETTINGS max_threads = 2, max_memory_usage = 536870912, " <>
      "max_bytes_before_external_group_by = 134217728, max_execution_time = 15"
  end

  defp bucket_key_sql(bucket, column) do
    "formatDateTime(toDateTime(#{bucket_sql(bucket)}(#{column}, 'UTC'), 'UTC'), " <>
      "'%Y-%m-%d %H:%i:%S', 'UTC')"
  end

  defp bucket_sql(:hour), do: "toStartOfHour"
  defp bucket_sql(:day), do: "toStartOfDay"
  defp bucket_sql(:month), do: "toStartOfMonth"

  defp bucket_key(%DateTime{} = start) do
    start |> DateTime.to_naive() |> NaiveDateTime.to_string()
  end

  defp build(period, window, experience_rows, delivery_rows, resolution_rows) do
    experience = group(experience_rows, &experience/1)
    delivery = group(delivery_rows, &delivery/1)

    report = %{
      period: period,
      bucket: window.bucket,
      experience: Map.get(experience, {"total", ""}, experience(List.duplicate(0, 12))),
      delivery: Map.get(delivery, {"total", ""}),
      series:
        Enum.map(window.buckets, fn start ->
          %{
            start: start,
            experience: Map.get(experience, {"series", bucket_key(start)}),
            delivery: Map.get(delivery, {"series", bucket_key(start)})
          }
        end),
      resolutions: resolutions(resolution_rows),
      breakdowns: Map.new(@dimensions, &{&1, breakdown(&1, experience, delivery)})
    }

    Map.put(report, :findings, findings(report))
  end

  defp group(rows, mapper) do
    Map.new(rows, fn [kind, key | values] -> {{kind, key}, mapper.(values)} end)
  end

  defp breakdown(dimension, experience, delivery) do
    kind = Atom.to_string(dimension)
    measured = for {{^kind, key}, value} <- experience, into: %{}, do: {key, value}

    delivered =
      if dimension in @delivery_dimensions,
        do: for({{^kind, key}, value} <- delivery, into: %{}, do: {key, value}),
        else: %{}

    (Map.keys(measured) ++ Map.keys(delivered))
    |> Enum.uniq()
    |> Enum.map(&%{key: &1, experience: measured[&1], delivery: delivered[&1]})
    |> Enum.sort_by(&{-attempts(&1), -requests(&1), &1.key})
    |> Enum.take(@breakdown_limit)
  end

  defp attempts(%{experience: %{attempts: attempts}}), do: attempts
  defp attempts(_row), do: 0

  defp requests(%{delivery: %{requests: requests}}), do: requests
  defp requests(_row), do: 0

  defp experience([
         attempts,
         startups,
         startup_p50,
         startup_p95,
         startup_failures,
         playback_failures,
         rebuffers,
         rebuffered_attempts,
         rebuffer_ms,
         playing_ms,
         bitrate_weight,
         bitrate_ms
       ]) do
    %{
      attempts: attempts,
      startups: startups,
      startup_p50_ms: if(startups > 0, do: round(startup_p50)),
      startup_p95_ms: if(startups > 0, do: round(startup_p95)),
      startup_failures: startup_failures,
      playback_failures: playback_failures,
      failure_rate: ratio(startup_failures + playback_failures, attempts),
      rebuffers: rebuffers,
      rebuffered_attempts: rebuffered_attempts,
      rebuffer_ms: rebuffer_ms,
      playing_ms: playing_ms,
      rebuffer_ratio: ratio(rebuffer_ms, rebuffer_ms + playing_ms),
      avg_bitrate: if(bitrate_ms > 0, do: round(bitrate_weight / bitrate_ms))
    }
  end

  defp delivery([
         requests,
         hits,
         misses,
         origin_requests,
         bytes,
         origin_bytes,
         ttfb_p50,
         ttfb_p95,
         client_errors,
         server_errors
       ]) do
    %{
      requests: requests,
      hits: hits,
      misses: misses,
      cache_hit_ratio: ratio(hits, hits + misses),
      origin_requests: origin_requests,
      bytes: bytes,
      origin_bytes: origin_bytes,
      ttfb_p50_ms: round(ttfb_p50),
      ttfb_p95_ms: round(ttfb_p95),
      client_errors: client_errors,
      server_errors: server_errors,
      error_rate: ratio(client_errors + server_errors, requests)
    }
  end

  defp resolutions(rows) do
    total = rows |> Enum.map(fn [_height, played_ms] -> played_ms end) |> Enum.sum()

    rows
    |> Enum.map(fn [height, played_ms] -> %{height: height, share: played_ms / max(total, 1)} end)
    |> Enum.sort_by(& &1.height, :desc)
  end

  defp ratio(_part, 0), do: nil
  defp ratio(part, whole), do: part / whole

  @doc """
  Segments whose viewers are clearly worse off than the space as a whole, with
  what delivery telemetry says about the cause.

  A segment is reported when its median startup time is at least 1.5 times and
  300 ms above the space, or its rebuffering or failure rate is at least twice
  the space's and half a point or two points above it, with at least ten
  affected plays so a few unlucky viewers do not count. For videos and regions the cause
  is a cache hit ratio 15 points lower, an edge latency 1.5 times higher, or a
  doubled error rate; otherwise delivery is considered healthy. The largest
  segments come first.
  """
  def findings(%{experience: overall, delivery: overall_delivery, breakdowns: breakdowns}) do
    for dimension <- @dimensions,
        %{experience: %{attempts: attempts} = segment} = row <- Map.fetch!(breakdowns, dimension),
        attempts >= @min_attempts and attempts < overall.attempts,
        symptoms = symptoms(segment, overall),
        symptoms != [] do
      %{
        dimension: dimension,
        key: row.key,
        attempts: attempts,
        symptoms: symptoms,
        causes: causes(dimension, row.delivery, overall_delivery)
      }
    end
    |> Enum.sort_by(&{-&1.attempts, &1.dimension, &1.key})
    |> Enum.take(@max_findings)
  end

  defp symptoms(segment, overall) do
    [
      (segment.startups >= @min_startups and
         worse?(segment.startup_p50_ms, overall.startup_p50_ms, 1.5, 300)) &&
        %{metric: :startup, value: segment.startup_p50_ms, baseline: overall.startup_p50_ms},
      (segment.rebuffered_attempts >= @min_affected and
         worse?(segment.rebuffer_ratio, overall.rebuffer_ratio, 2, 0.005)) &&
        %{metric: :rebuffering, value: segment.rebuffer_ratio, baseline: overall.rebuffer_ratio},
      (segment.startup_failures + segment.playback_failures >= @min_affected and
         worse?(segment.failure_rate, overall.failure_rate, 2, 0.02)) &&
        %{metric: :failures, value: segment.failure_rate, baseline: overall.failure_rate}
    ]
    |> Enum.filter(&is_map/1)
  end

  defp causes(dimension, _delivery, _overall) when dimension not in @delivery_dimensions,
    do: [%{type: :client}]

  defp causes(_dimension, %{requests: requests} = delivery, %{} = overall)
       when requests >= @min_requests do
    causes =
      [
        (is_number(delivery.cache_hit_ratio) and is_number(overall.cache_hit_ratio) and
           delivery.cache_hit_ratio <= overall.cache_hit_ratio - 0.15) &&
          %{
            type: :cache_misses,
            value: delivery.cache_hit_ratio,
            baseline: overall.cache_hit_ratio
          },
        worse?(delivery.ttfb_p95_ms, overall.ttfb_p95_ms, 1.5, 100) &&
          %{type: :slow_edge, value: delivery.ttfb_p95_ms, baseline: overall.ttfb_p95_ms},
        worse?(delivery.error_rate, overall.error_rate, 2, 0.01) &&
          %{type: :delivery_errors, value: delivery.error_rate, baseline: overall.error_rate}
      ]
      |> Enum.filter(&is_map/1)

    if causes == [], do: [%{type: :delivery_healthy}], else: causes
  end

  defp causes(_dimension, _delivery, _overall), do: [%{type: :no_delivery_data}]

  defp worse?(value, baseline, factor, margin) when is_number(value) and is_number(baseline),
    do: value >= baseline * factor and value - baseline >= margin

  defp worse?(_value, _baseline, _factor, _margin), do: false

  defp database do
    case ClickHouseRepo.config()[:database] || "mave_metrics" do
      db_name when is_binary(db_name) ->
        if db_name =~ @clickhouse_identifier, do: db_name, else: "mave_metrics"

      _ ->
        "mave_metrics"
    end
  end
end
