defmodule MaveCore.Analytics.RangeReport do
  @moduledoc false

  alias MaveCore.Analytics.Range
  alias MaveCore.ClickHouseRepo
  alias MaveCore.SharedStorageSpace

  @empty %{views: 0, watch_seconds: 0.0, completion_rate: nil}

  def fetch(space_hash, %Range{} = range, embed_hash \\ nil) do
    hashes = if embed_hash, do: [embed_hash], else: []

    with {:ok, rows} <- fetch_rows(space_hash, range, hashes, :series) do
      metrics = Map.new(rows, fn [bucket | values] -> {bucket, metrics(values)} end)

      {:ok,
       %{
         from: range.from,
         to: range.to,
         timezone: "UTC",
         granularity: range.granularity,
         totals: Map.get(metrics, "", @empty),
         series:
           Enum.map(Range.buckets(range), fn date ->
             metrics |> Map.get(Date.to_iso8601(date), @empty) |> Map.put(:date, date)
           end)
       }}
    end
  end

  def videos(space_hash, %Range{} = range, hashes) when is_list(hashes) do
    with {:ok, rows} <- fetch_rows(space_hash, range, hashes, :videos) do
      {:ok, Map.new(rows, fn [hash | values] -> {hash, metrics(values)} end)}
    end
  end

  def attach(data, space_hash, range, embed_hash \\ nil)
  def attach(data, _space_hash, nil, _embed_hash), do: {:ok, data}

  def attach(data, space_hash, range, embed_hash) do
    with {:ok, report} <- fetch(space_hash, range, embed_hash) do
      {:ok, Map.put(data, :range, report)}
    end
  end

  def empty_metrics, do: @empty

  defp fetch_rows(space_hash, range, hashes, kind) do
    if SharedStorageSpace.hash?(space_hash) do
      {:ok, []}
    else
      {from, until} = Range.bounds(range)
      sql = segments_sql() <> aggregate_sql(kind, range.granularity)

      # All user-controlled values are native ClickHouse parameters. SQL fragments
      # below are fixed strings selected from the validated granularity enum.
      case ClickHouseRepo.query(sql, [space_hash, from, until, hashes], timeout: 60_000) do
        {:ok, %{rows: rows}} -> {:ok, rows}
        {:error, _reason} -> {:error, :analytics_unavailable}
      end
    end
  end

  defp segments_sql do
    """
    /* mave_perf:analytics.range */
    WITH ordered AS (
      SELECT embed_hash, session_id, timestamp, name, video_time, duration,
        leadInFrame(timestamp) OVER events_window AS next_ts,
        leadInFrame(name) OVER events_window AS next_name,
        leadInFrame(video_time) OVER events_window AS next_video_time
      FROM events
      PREWHERE space_hash = {$0:String}
        AND (empty({$3:Array(String)}) OR embed_hash IN {$3:Array(String)})
      WHERE name IN ('play', 'pause')
      WINDOW events_window AS (
        PARTITION BY embed_hash, session_id ORDER BY timestamp, name
        ROWS BETWEEN UNBOUNDED PRECEDING AND UNBOUNDED FOLLOWING
      )
    ), segments AS (
      SELECT embed_hash, session_id, timestamp, next_ts, video_time, next_video_time, duration,
        greatest(timestamp, {$1:DateTime64(6, 'UTC')}) AS start_ts,
        least(next_ts, {$2:DateTime64(6, 'UTC')}) AS end_ts
      FROM ordered
      WHERE name = 'play' AND next_name = 'pause'
        AND next_ts > {$1:DateTime64(6, 'UTC')}
        AND timestamp < {$2:DateTime64(6, 'UTC')}
        AND next_ts > timestamp
    ), daily AS (
      SELECT *,
        addDays(toDate(start_ts, 'UTC'), arrayJoin(range(
          toUInt32(dateDiff('day', toDate(start_ts, 'UTC'), toDate(end_ts - INTERVAL 1 MICROSECOND, 'UTC')) + 1)
        ))) AS day
      FROM segments WHERE end_ts > start_ts
    ), clipped AS (
      SELECT embed_hash, session_id, day,
        greatest(start_ts, toDateTime64(day, 6, 'UTC')) AS clipped_start,
        least(end_ts, toDateTime64(addDays(day, 1), 6, 'UTC')) AS clipped_end,
        dateDiff('microsecond', clipped_start, clipped_end) / 1000000.0 AS watch_seconds,
        if(isFinite(duration) AND duration > 0
          AND isFinite(video_time) AND isFinite(next_video_time),
          least(1.0, greatest(0.0,
            (video_time + (next_video_time - video_time) *
              dateDiff('microsecond', timestamp, clipped_end) /
              dateDiff('microsecond', timestamp, next_ts)) / duration)),
          NULL) AS completion
      FROM daily
    ),
    """
  end

  defp aggregate_sql(:videos, _granularity) do
    """
    sessions AS (
      SELECT embed_hash, session_id, sum(watch_seconds) AS watched, max(completion) AS reached
      FROM clipped GROUP BY embed_hash, session_id
    )
    SELECT embed_hash, countIf(watched >= 1), sum(watched),
      avgOrNullIf(reached, watched >= 1 AND isNotNull(reached))
    FROM sessions GROUP BY embed_hash
    SETTINGS max_execution_time = 55
    """
  end

  defp aggregate_sql(:series, granularity) do
    bucket = bucket_expression(granularity)

    """
    sessions AS (
      SELECT session_id, #{bucket} AS bucket, grouping(bucket) AS total,
        sum(watch_seconds) AS watched, max(completion) AS reached
      FROM clipped GROUP BY GROUPING SETS ((session_id, bucket), (session_id))
    )
    SELECT if(total = 1, '', toString(bucket)), countIf(watched >= 1), sum(watched),
      avgOrNullIf(reached, watched >= 1 AND isNotNull(reached))
    FROM sessions GROUP BY total, bucket
    SETTINGS max_execution_time = 55
    """
  end

  defp bucket_expression("day"), do: "day"
  defp bucket_expression("week"), do: "toMonday(day)"
  defp bucket_expression("month"), do: "toStartOfMonth(day)"

  defp metrics([views, watch_seconds, completion_rate]) do
    %{views: views, watch_seconds: watch_seconds, completion_rate: completion_rate}
  end
end
