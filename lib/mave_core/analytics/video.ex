defmodule MaveCore.Analytics.Video do
  @moduledoc false

  alias Ecto.Adapters.SQL
  alias MaveCore.ClickHouseRepo

  @clickhouse_identifier ~r/^[A-Za-z_][A-Za-z0-9_]*$/
  @min_watch_seconds 1
  # Bound both ClickHouse's seconds table and the API's per-second allocation.
  @max_dropoff_seconds 4 * 60 * 60

  def data(embed_id) when is_binary(embed_id) do
    with {:ok, %{space_hash: space_hash, embed_hash: embed_hash}} <- parse_embed_id(embed_id) do
      data(space_hash, embed_hash)
    end
  end

  def data(space_hash, embed_hash) when is_binary(space_hash) and is_binary(embed_hash) do
    with {:ok, space_hash} <- parse_space_hash(space_hash),
         {:ok, embed_hash} <- parse_embed_hash(embed_hash) do
      now = DateTime.utc_now()

      today_from = DateTime.new!(DateTime.to_date(now), ~T[00:00:00], "Etc/UTC")
      month_from = DateTime.new!(Date.new!(now.year, now.month, 1), ~T[00:00:00], "Etc/UTC")
      year_from = DateTime.new!(Date.new!(now.year, 1, 1), ~T[00:00:00], "Etc/UTC")

      views_task =
        Task.async(fn ->
          get_views_counts(space_hash, embed_hash, today_from, month_from, year_from, now)
        end)

      dropoff_task =
        Task.async(fn -> get_dropoff_year(space_hash, embed_hash, year_from, now) end)

      sources_task =
        Task.async(fn -> get_sources_year(space_hash, embed_hash, year_from, now) end)

      %{today: views_today, month: views_month, year: views_year} =
        await_task(views_task, %{today: 0, month: 0, year: 0})

      dropoff = await_task(dropoff_task, %{duration_seconds: 0, per_second: []})
      sources = await_task(sources_task, [])

      {:ok,
       %{
         id: "#{space_hash}#{embed_hash}",
         views: %{
           today: views_today,
           month: views_month,
           year: views_year
         },
         dropoff: dropoff,
         sources: sources
       }}
    end
  end

  def data(_, _), do: {:error, :invalid_embed_id}

  defp await_task(task, default) do
    Task.await(task, 60_000)
  catch
    :exit, _ -> default
  end

  defp parse_embed_id(embed_id) when is_binary(embed_id) do
    embed_id = String.trim(embed_id)

    case embed_id do
      <<space_hash::binary-size(5), embed_hash::binary-size(10)>> ->
        with {:ok, space_hash} <- parse_space_hash(space_hash),
             {:ok, embed_hash} <- parse_embed_hash(embed_hash) do
          {:ok, %{space_hash: space_hash, embed_hash: embed_hash}}
        end

      _ ->
        {:error, :invalid_embed_id}
    end
  end

  defp parse_space_hash(space_hash) when is_binary(space_hash) do
    case String.trim(space_hash) do
      <<_::binary-size(5)>> = value ->
        if valid_hash?(value), do: {:ok, value}, else: {:error, :invalid_embed_id}

      _ ->
        {:error, :invalid_embed_id}
    end
  end

  defp parse_embed_hash(embed_hash) when is_binary(embed_hash) do
    case String.trim(embed_hash) do
      <<_::binary-size(10)>> = value ->
        if valid_hash?(value), do: {:ok, value}, else: {:error, :invalid_embed_id}

      _ ->
        {:error, :invalid_embed_id}
    end
  end

  defp valid_hash?(value), do: String.match?(value, ~r/^[A-Za-z0-9]+$/)

  defp get_views_counts(space_hash, embed_hash, today_from_dt, month_from_dt, year_from_dt, to_dt) do
    db_name = clickhouse_database_name()

    today_from_lit = datetime_literal(today_from_dt)
    month_from_lit = datetime_literal(month_from_dt)
    year_from_lit = datetime_literal(year_from_dt)
    to_lit = datetime_literal(to_dt)

    sql = """
    /* mave_perf:videos.views_counts */
    WITH ordered AS (
      SELECT
        session_id,
        timestamp,
        name,
        leadInFrame(timestamp) OVER (
          PARTITION BY session_id
          ORDER BY timestamp
          ROWS BETWEEN UNBOUNDED PRECEDING AND UNBOUNDED FOLLOWING
        ) AS next_ts,
        leadInFrame(name) OVER (
          PARTITION BY session_id
          ORDER BY timestamp
          ROWS BETWEEN UNBOUNDED PRECEDING AND UNBOUNDED FOLLOWING
        ) AS next_name
      FROM #{db_name}.events
      PREWHERE space_hash = #{string_literal(space_hash)}
        AND embed_hash = #{string_literal(embed_hash)}
        AND timestamp >= #{year_from_lit}
        AND timestamp < #{to_lit}
      WHERE name IN ('play', 'pause')
    ),
    sessions AS (
      SELECT
        session_id,
        sumIf(
          greatest(toInt64(0), toUnixTimestamp64Milli(next_ts) - toUnixTimestamp64Milli(timestamp)),
          name = 'play' AND next_name IN ('pause') AND timestamp >= #{today_from_lit}
        ) AS watch_ms_today,
        sumIf(
          greatest(toInt64(0), toUnixTimestamp64Milli(next_ts) - toUnixTimestamp64Milli(timestamp)),
          name = 'play' AND next_name IN ('pause') AND timestamp >= #{month_from_lit}
        ) AS watch_ms_month,
        sumIf(
          greatest(toInt64(0), toUnixTimestamp64Milli(next_ts) - toUnixTimestamp64Milli(timestamp)),
          name = 'play' AND next_name IN ('pause')
        ) AS watch_ms_year
      FROM ordered
      GROUP BY session_id
    )
    SELECT
      countIf(watch_ms_today >= #{@min_watch_seconds * 1000}) AS views_today,
      countIf(watch_ms_month >= #{@min_watch_seconds * 1000}) AS views_month,
      countIf(watch_ms_year >= #{@min_watch_seconds * 1000}) AS views_year
    FROM sessions
    """

    query_clickhouse(sql, %{today: 0, month: 0, year: 0}, fn [
                                                               [
                                                                 views_today,
                                                                 views_month,
                                                                 views_year
                                                               ]
                                                             ] ->
      %{today: views_today, month: views_month, year: views_year}
    end)
  end

  defp get_dropoff_year(space_hash, embed_hash, from_dt, to_dt) do
    db_name = clickhouse_database_name()

    from_lit = datetime_literal(from_dt)
    to_lit = datetime_literal(to_dt)

    duration = get_duration_seconds(db_name, space_hash, embed_hash, from_lit, to_lit)

    views_per_second =
      get_engagement_per_second_distribution(
        db_name,
        space_hash,
        embed_hash,
        from_lit,
        to_lit,
        duration
      )
      |> build_views_per_second(duration)

    %{
      duration_seconds: duration,
      per_second: views_per_second
    }
  end

  defp get_sources_year(space_hash, embed_hash, from_dt, to_dt) do
    db_name = clickhouse_database_name()

    from_lit = datetime_literal(from_dt)
    to_lit = datetime_literal(to_dt)

    raw_sources = get_top_first_source_urls(db_name, space_hash, embed_hash, from_lit, to_lit)

    grouped =
      raw_sources
      |> Enum.map(fn %{source_url: source_url, views: views} ->
        uri = URI.parse(source_url || "")
        host = uri.host
        path = if uri.path in [nil, ""], do: "/", else: uri.path
        %{host: host, path: path, views: views}
      end)
      |> Enum.filter(&is_binary(&1.host))
      |> Enum.reject(fn %{host: host} -> internal_source_host?(host) end)
      |> Enum.group_by(fn %{host: host, path: path} -> {host, path} end)
      |> Enum.map(fn {{host, path}, items} ->
        %{
          host: host,
          path: path,
          views: Enum.reduce(items, 0, fn item, acc -> acc + item.views end)
        }
      end)
      |> Enum.sort_by(& &1.views, :desc)
      |> Enum.take(20)

    total_views = Enum.reduce(grouped, 0, fn item, acc -> item.views + acc end)

    if total_views == 0 do
      []
    else
      grouped
      |> Enum.map(fn item ->
        %{path: display_source_path(item), percentage: item.views / total_views * 100}
      end)
      |> normalize_percentages()
    end
  end

  @doc false
  def internal_source_host?(host) when is_binary(host) do
    normalized_host = host |> String.trim() |> String.downcase() |> String.trim_trailing(".")

    :mave_core
    |> Application.get_env(:analytics_internal_source_hosts, [])
    |> Enum.filter(&is_binary/1)
    |> Enum.map(&(String.trim(&1) |> String.downcase() |> String.trim_trailing(".")))
    |> Enum.reject(&(&1 == ""))
    |> Enum.any?(fn configured_host ->
      normalized_host == configured_host or
        String.ends_with?(normalized_host, ".#{configured_host}")
    end)
  end

  def internal_source_host?(_host), do: false

  defp display_source_path(%{host: host, path: "/"}), do: host
  defp display_source_path(%{host: host, path: path}), do: shorten("#{host}#{path}", 75)

  defp get_duration_seconds(db_name, space_hash, embed_hash, from_lit, to_lit) do
    sql = """
    /* mave_perf:videos.duration */
    SELECT toUInt32(ceil(maxIf(duration,
      isFinite(duration) AND duration > 0 AND duration <= #{@max_dropoff_seconds})))
    FROM #{db_name}.events
    PREWHERE space_hash = #{string_literal(space_hash)}
      AND embed_hash = #{string_literal(embed_hash)}
      AND timestamp >= #{from_lit}
      AND timestamp < #{to_lit}
    """

    query_clickhouse(sql, 0, fn
      [[duration]] -> bounded_duration_seconds(duration)
      _ -> 0
    end)
  end

  @doc false
  def bounded_duration_seconds(duration)
      when is_number(duration) and duration > 0 and duration <= @max_dropoff_seconds,
      do: ceil(duration)

  def bounded_duration_seconds(_duration), do: 0

  defp get_engagement_per_second_distribution(
         db_name,
         space_hash,
         embed_hash,
         from_lit,
         to_lit,
         duration
       )
       when is_integer(duration) and duration > 0 and duration <= @max_dropoff_seconds do
    max_second = duration - 1

    sql = """
    /* mave_perf:videos.dropoff_distribution */
    WITH ordered AS (
      SELECT
        session_id,
        timestamp,
        name,
        video_time,
        leadInFrame(video_time) OVER (
          PARTITION BY session_id
          ORDER BY timestamp
          ROWS BETWEEN UNBOUNDED PRECEDING AND UNBOUNDED FOLLOWING
        ) AS next_video_time,
        leadInFrame(timestamp) OVER (
          PARTITION BY session_id
          ORDER BY timestamp
          ROWS BETWEEN UNBOUNDED PRECEDING AND UNBOUNDED FOLLOWING
        ) AS next_ts,
        leadInFrame(name) OVER (
          PARTITION BY session_id
          ORDER BY timestamp
          ROWS BETWEEN UNBOUNDED PRECEDING AND UNBOUNDED FOLLOWING
        ) AS next_name
      FROM #{db_name}.events
      PREWHERE space_hash = #{string_literal(space_hash)}
        AND embed_hash = #{string_literal(embed_hash)}
        AND timestamp >= #{from_lit}
        AND timestamp < #{to_lit}
      WHERE name IN ('play', 'pause')
    ),
    session_watch AS (
      SELECT
        session_id,
        sumIf(
          greatest(toInt64(0), toUnixTimestamp64Milli(next_ts) - toUnixTimestamp64Milli(timestamp)),
          name = 'play' AND next_name IN ('pause')
        ) AS watch_ms
      FROM ordered
      GROUP BY session_id
    ),
    intervals AS (
      SELECT
        session_id,
        least(toUInt32(#{max_second}), toUInt32(floor(greatest(video_time, 0.0)))) AS start_s,
        least(
          toUInt32(#{max_second}),
          toUInt32(floor(greatest(next_video_time - 0.000001, 0.0)))
        ) AS end_s
      FROM ordered
      WHERE name = 'play'
        AND next_name IN ('pause')
        AND video_time IS NOT NULL
        AND next_video_time IS NOT NULL
        AND next_video_time >= video_time
    ),
    filtered_intervals AS (
      SELECT
        session_id,
        start_s,
        end_s
      FROM intervals
      INNER JOIN session_watch USING (session_id)
      WHERE watch_ms >= #{@min_watch_seconds * 1000}
        AND end_s >= start_s
        AND start_s <= toUInt32(#{max_second})
    ),
    session_deltas AS (
      SELECT
        session_id,
        second,
        sum(delta) AS delta
      FROM (
        SELECT session_id, start_s AS second, 1 AS delta FROM filtered_intervals
        UNION ALL
        SELECT session_id, (end_s + 1) AS second, -1 AS delta FROM filtered_intervals
      )
      WHERE second <= toUInt32(#{duration})
      GROUP BY session_id, second
    ),
    session_activity AS (
      SELECT
        session_id,
        second,
        sum(delta) OVER (
          PARTITION BY session_id
          ORDER BY second
          ROWS BETWEEN UNBOUNDED PRECEDING AND CURRENT ROW
        ) AS active
      FROM session_deltas
    ),
    session_transitions AS (
      SELECT
        session_id,
        second,
        active,
        lagInFrame(active, 1, 0) OVER (
          PARTITION BY session_id
          ORDER BY second
          ROWS BETWEEN UNBOUNDED PRECEDING AND CURRENT ROW
        ) AS previous_active
      FROM session_activity
    ),
    merged_deltas AS (
      SELECT
        second,
        sum(delta) AS delta
      FROM (
        SELECT second, 1 AS delta
        FROM session_transitions
        WHERE previous_active = 0 AND active > 0
        UNION ALL
        SELECT second, -1 AS delta
        FROM session_transitions
        WHERE previous_active > 0 AND active = 0
      )
      GROUP BY second
    )
    SELECT
      second,
      sum(ifNull(delta, 0)) OVER (
        ORDER BY second
        ROWS BETWEEN UNBOUNDED PRECEDING AND CURRENT ROW
      ) AS views
    FROM (
      SELECT number AS second
      FROM numbers(#{duration})
    ) AS seconds
    LEFT JOIN merged_deltas USING (second)
    ORDER BY second
    """

    query_clickhouse(sql, [], fn rows ->
      Enum.map(rows, fn [second, views] -> %{second: second, views: views} end)
    end)
  end

  defp get_engagement_per_second_distribution(
         _db_name,
         _space_hash,
         _embed_hash,
         _from_lit,
         _to_lit,
         _duration
       ) do
    []
  end

  defp build_views_per_second(distribution, duration)
       when is_integer(duration) and duration > 0 and duration <= @max_dropoff_seconds do
    exact =
      Enum.reduce(distribution, %{}, fn %{second: second, views: views}, acc ->
        Map.put(acc, second, views)
      end)

    Enum.map(0..(duration - 1), fn second ->
      Map.get(exact, second, 0)
    end)
  end

  defp build_views_per_second(_distribution, _duration), do: []

  defp get_top_first_source_urls(db_name, space_hash, embed_hash, from_lit, to_lit) do
    sql = """
    /* mave_perf:videos.sources */
    WITH ordered AS (
      SELECT
        session_id,
        timestamp,
        name,
        source_url,
        leadInFrame(timestamp) OVER (
          PARTITION BY session_id
          ORDER BY timestamp
          ROWS BETWEEN UNBOUNDED PRECEDING AND UNBOUNDED FOLLOWING
        ) AS next_ts,
        leadInFrame(name) OVER (
          PARTITION BY session_id
          ORDER BY timestamp
          ROWS BETWEEN UNBOUNDED PRECEDING AND UNBOUNDED FOLLOWING
        ) AS next_name
      FROM #{db_name}.events
      PREWHERE space_hash = #{string_literal(space_hash)}
        AND embed_hash = #{string_literal(embed_hash)}
        AND timestamp >= #{from_lit}
        AND timestamp < #{to_lit}
      WHERE name IN ('play', 'pause')
    ),
    session_stats AS (
      SELECT
        session_id,
        sumIf(
          greatest(toInt64(0), toUnixTimestamp64Milli(next_ts) - toUnixTimestamp64Milli(timestamp)),
          name = 'play' AND next_name IN ('pause')
        ) AS watch_ms,
        argMin(source_url, timestamp) AS first_source_url
      FROM ordered
      GROUP BY session_id
    )
    SELECT
      first_source_url,
      countIf(watch_ms >= #{@min_watch_seconds * 1000}) AS views
    FROM session_stats
    GROUP BY first_source_url
    ORDER BY views DESC
    LIMIT 200
    """

    query_clickhouse(sql, [], fn rows ->
      Enum.map(rows, fn [url, views] -> %{source_url: url, views: views} end)
    end)
  end

  defp normalize_percentages(items) do
    floored_sum =
      Enum.reduce(items, 0, fn item, acc -> acc + trunc(Float.floor(item.percentage)) end)

    diff = 100 - floored_sum

    items
    |> Enum.with_index()
    |> Enum.map(fn {item, index} ->
      floored = trunc(Float.floor(item.percentage))
      percentage = if index < diff, do: floored + 1, else: floored
      Map.put(item, :percentage, percentage)
    end)
  end

  defp shorten(text, max_len) when is_binary(text) and is_integer(max_len) and max_len > 0 do
    if String.length(text) <= max_len do
      text
    else
      String.slice(text, 0, max_len - 1) <> "…"
    end
  end

  defp datetime_literal(dt) do
    iso = DateTime.to_iso8601(dt)
    "parseDateTime64BestEffort(#{string_literal(iso)})"
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
  defp query_clickhouse(sql, default, mapper) when is_binary(sql) and is_function(mapper, 1) do
    case SQL.query(ClickHouseRepo, sql, []) do
      {:ok, %{rows: rows}} -> mapper.(rows)
      _ -> default
    end
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
