defmodule MaveCore.Experiments.Metrics do
  @moduledoc """
  Reads what viewers of an A/B test did from the raw playback events.

  The embed page plays the assigned variant under the variant's own embed ID,
  and playback events carry the page they were sent from. Views of a variant
  count towards a test only when they came from the tested embed's page, so
  the same video embedded elsewhere does not influence the result.
  """

  alias Ecto.Adapters.SQL
  alias MaveCore.ClickHouseRepo

  @min_watch_ms 1_000
  # A view counts as completed once playback reached this share of the video.
  @completion_threshold 0.9
  # An unclosed tab must not outweigh every other viewer.
  @max_watch_seconds 4 * 60 * 60

  @type variant_metrics :: %{
          views: non_neg_integer(),
          watch_seconds: float(),
          watch_variance: float(),
          completions: non_neg_integer()
        }

  def completion_threshold, do: @completion_threshold

  @doc """
  Returns per-variant metrics keyed by the variant's embed hash.

  Variants without views are included with zeroes. Returns
  `{:error, :analytics_unavailable}` when ClickHouse cannot answer.
  """
  @spec variants(String.t(), String.t(), [String.t()], DateTime.t(), DateTime.t()) ::
          {:ok, %{String.t() => variant_metrics()}} | {:error, :analytics_unavailable}
  def variants(space_hash, host_embed_hash, variant_embed_hashes, from, to)
      when is_binary(space_hash) and is_binary(host_embed_hash) and is_list(variant_embed_hashes) do
    sql = """
    /* mave_perf:experiments.variants */
    WITH ordered AS (
      SELECT
        embed_hash,
        session_id,
        timestamp,
        name,
        video_time,
        duration,
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
      FROM events
      PREWHERE space_hash = {$0:String}
        AND embed_hash IN {$1:Array(String)}
        AND timestamp >= {$2:DateTime64(6)}
        AND timestamp < {$3:DateTime64(6)}
      WHERE name IN ('play', 'pause')
        AND endsWith(source_url, {$4:String})
    ),
    views AS (
      SELECT
        embed_hash,
        sumIf(
          greatest(toInt64(0), toUnixTimestamp64Milli(next_ts) - toUnixTimestamp64Milli(timestamp)),
          name = 'play' AND next_name = 'pause'
        ) AS watch_ms,
        least(watch_ms / 1000, #{@max_watch_seconds}) AS watched,
        max(duration) AS video_duration,
        max(video_time) AS furthest
      FROM ordered
      GROUP BY embed_hash, session_id
      HAVING watch_ms >= #{@min_watch_ms}
    )
    SELECT
      embed_hash,
      count() AS views,
      toFloat64(avg(watched)) AS watch_seconds,
      toFloat64(ifNotFinite(varSamp(watched), 0)) AS watch_variance,
      countIf(video_duration > 0 AND furthest >= video_duration * #{@completion_threshold}) AS completions
    FROM views
    GROUP BY embed_hash
    """

    params = [
      space_hash,
      variant_embed_hashes,
      from,
      to,
      "/" <> host_embed_hash <> "/player.html"
    ]

    case query(sql, params) do
      {:ok, %{rows: rows}} ->
        found =
          Map.new(rows, fn [hash, views, watch_seconds, watch_variance, completions] ->
            {hash,
             %{
               views: views,
               watch_seconds: watch_seconds * 1.0,
               watch_variance: watch_variance * 1.0,
               completions: completions
             }}
          end)

        {:ok, Map.new(variant_embed_hashes, &{&1, Map.get(found, &1, empty())})}

      _error ->
        {:error, :analytics_unavailable}
    end
  end

  def empty, do: %{views: 0, watch_seconds: 0.0, watch_variance: 0.0, completions: 0}

  # sobelow_skip ["SQL.Query"]
  defp query(sql, params) do
    SQL.query(ClickHouseRepo, sql, params, timeout: 20_000)
  rescue
    _error -> {:error, :analytics_unavailable}
  end
end
