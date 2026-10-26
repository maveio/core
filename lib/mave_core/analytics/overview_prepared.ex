defmodule MaveCore.Analytics.OverviewPrepared do
  @moduledoc false

  def build(breakdowns? \\ false) do
    extra_columns = if breakdowns?, do: ", events.8, events.9", else: ""
    extra_fields = if breakdowns?, do: ",e.9,domainWithoutWWW(e.10)", else: ""
    extra_events = if breakdowns?, do: ",e.8,e.9", else: ""

    """
    INSERT INTO #{days_table(breakdowns?)}
    WITH event_rows AS (
      SELECT session_id, arrayJoin(arrayZip(arrayEnumerate(events.1),
        events.1, events.2, events.3, events.4, events.5, events.6, events.7#{extra_columns})) AS e
      FROM analytics_sessions
      PREWHERE space_hash = {$0:String} AND bucket = {$1:UInt8} AND generation = {$2:UUID}
      WHERE ({$4:UInt8} = 1 OR session_id IN {$3:Array(UUID)})
    ), grouped AS (
      SELECT session_id, e.2 AS embed_hash, toDate(e.3, 'UTC') AS day,
        arraySort(e -> e.1, groupArray((e.1,e.3,e.4,e.5,e.6,e.7,e.8#{extra_fields}))) AS ev
      FROM event_rows GROUP BY session_id, embed_hash, day
    ), span_rows AS (
      SELECT session_id, arrayJoin(arrayZip(segments.1,segments.2,segments.3)) AS s
      FROM analytics_sessions
      PREWHERE space_hash = {$0:String} AND bucket = {$1:UInt8} AND generation = {$2:UUID}
      WHERE ({$4:UInt8} = 1 OR session_id IN {$3:Array(UUID)})
    ), spans AS (
      SELECT session_id, s.1 AS embed_hash, toDate(s.2, 'UTC') AS day,
        groupArray((s.2,s.3)) AS pairs
      FROM span_rows GROUP BY session_id, embed_hash, day
    )
    SELECT {$0:String},{$1:UInt8},{$2:UUID},g.session_id,g.embed_hash,g.day,
      ev[1].2,ev[-1].2,ev[1].6,ev[1].7,
      arrayMax(e -> e.5,ev),arrayMax(e -> e.4,ev),
      arraySum(s -> greatest(toInt64(0),dateDiff('millisecond',s.1,s.2)),pairs),
      arrayMax(s -> s.2,pairs),
      arrayMap(e -> (e.2,e.3,e.4,e.5,e.6,e.7#{extra_events}),ev),pairs
    FROM grouped AS g LEFT JOIN spans AS s
      ON g.session_id=s.session_id AND g.embed_hash=s.embed_hash AND g.day=s.day
    SETTINGS join_use_nulls=0, max_threads=1, max_block_size=128,
      max_memory_usage=#{setting(:build_memory_bytes, 1_073_741_824)}, max_bytes_before_external_group_by=268435456,
      max_execution_time=60
    """
  end

  def copy(breakdowns? \\ false) do
    """
    INSERT INTO #{days_table(breakdowns?)}
    SELECT * REPLACE({$2:UUID} AS generation) FROM #{days_table(breakdowns?)}
    PREWHERE space_hash={$0:String} AND bucket={$1:UInt8} AND generation={$3:UUID}
    WHERE session_id NOT IN {$4:Array(UUID)}
    SETTINGS max_threads=1, max_block_size=128, max_memory_usage=536870912,
      min_insert_block_size_rows=0, min_insert_block_size_bytes=16777216,
      max_insert_block_size=16384, max_execution_time=60
    """
  end

  def build_views(breakdowns? \\ false) do
    extra_sources =
      if breakdowns?, do: ",argMin(events[1].7,first_at),argMin(events[1].8,first_at)", else: ""

    """
    INSERT INTO #{views_table(breakdowns?)}
    SELECT {$0:String},{$1:UInt8},{$2:UUID},session_id,embed_hash,
      min(first_at),max(last_at),argMin(device,first_at),argMin(browser,first_at),
      max(duration),max(furthest),sum(watch_ms),max(last_span_end)#{extra_sources}
    FROM #{days_table(breakdowns?)}
    PREWHERE space_hash={$0:String} AND bucket={$1:UInt8} AND generation={$2:UUID}
    WHERE ({$4:UInt8}=1 OR session_id IN {$3:Array(UUID)})
    GROUP BY session_id,embed_hash
    SETTINGS max_threads=1, max_block_size=128,
      max_memory_usage=#{setting(:build_memory_bytes, 1_073_741_824)},
      max_bytes_before_external_group_by=268435456, max_execution_time=60
    """
  end

  def copy_views(breakdowns? \\ false),
    do: String.replace(copy(breakdowns?), days_table(breakdowns?), views_table(breakdowns?))

  def views_cte(breakdowns? \\ false) do
    compact_sources = if breakdowns?, do: ",os,website", else: ""

    boundary_sources =
      if breakdowns?,
        do: ",argMin(ev[1].7,ev[1].1) AS os,argMin(ev[1].8,ev[1].1) AS website",
        else: ""

    source_columns =
      if breakdowns?, do: ",nullIf(os,'') AS os,nullIf(website,'') AS website", else: ""

    """
    WITH compact AS (
      SELECT embed_hash,first_at AS started_at,device,browser,duration AS video_duration,furthest,watch_ms#{compact_sources}
      FROM #{views_table(breakdowns?)}
      PREWHERE space_hash={$0:String} AND generation IN {$1:Array(UUID)}
        AND first_at>={$2:DateTime64(6)} AND first_at<{$3:DateTime64(6)}
      WHERE last_at<{$3:DateTime64(6)} AND last_span_end<{$3:DateTime64(6)}
    ), boundary_ids AS (
      SELECT session_id,embed_hash FROM #{views_table(breakdowns?)}
      PREWHERE space_hash={$0:String} AND generation IN {$1:Array(UUID)}
        AND first_at<{$3:DateTime64(6)}
      WHERE last_at>={$2:DateTime64(6)} AND
        (first_at<{$2:DateTime64(6)} OR last_at>={$3:DateTime64(6)} OR last_span_end>={$3:DateTime64(6)})
    ), boundary AS (
      SELECT session_id,embed_hash,
        arrayFilter(e -> e.1>={$2:DateTime64(6)} AND e.1<{$3:DateTime64(6)},events) AS ev,
        arrayFilter(s -> s.1>={$2:DateTime64(6)} AND s.2<{$3:DateTime64(6)},spans) AS pairs
      FROM #{days_table(breakdowns?)}
      PREWHERE space_hash={$0:String} AND generation IN {$1:Array(UUID)}
        AND day>=toDate({$2:DateTime64(6)},'UTC') AND day<=toDate({$3:DateTime64(6)},'UTC')
        AND (session_id,embed_hash) IN boundary_ids
    ), per_video AS (
      SELECT session_id,embed_hash,min(ev[1].1) AS started_at,
        argMin(ev[1].5,ev[1].1) AS device,argMin(ev[1].6,ev[1].1) AS browser,
        max(arrayMax(e -> e.4,ev)) AS video_duration,max(arrayMax(e -> e.3,ev)) AS furthest,
        sum(arraySum(s -> greatest(toInt64(0),dateDiff('millisecond',s.1,s.2)),pairs)) AS watch_ms#{boundary_sources}
      FROM boundary WHERE notEmpty(ev) GROUP BY session_id,embed_hash
    ), eligible AS (
      SELECT * FROM compact
      UNION ALL
      SELECT embed_hash,started_at,device,browser,video_duration,furthest,watch_ms#{compact_sources} FROM per_video
    ), views AS (
      SELECT embed_hash,started_at,nullIf(lower(device),'') AS device,nullIf(browser,'') AS browser#{source_columns},
        video_duration,watch_ms,if(video_duration>0,least(1,furthest/video_duration),0) AS completion
      FROM eligible WHERE watch_ms>=1000
    )
    """
  end

  defp days_table(true), do: "analytics_breakdown_days"
  defp days_table(false), do: "analytics_overview_days"
  defp views_table(true), do: "analytics_breakdown_views"
  defp views_table(false), do: "analytics_overview_views"

  defp setting(key, default),
    do: Keyword.get(Application.get_env(:mave_core, :analytics_sessions, []), key, default)
end
