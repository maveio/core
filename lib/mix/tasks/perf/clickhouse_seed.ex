defmodule Mix.Tasks.Perf.ClickHouseSeed do
  @moduledoc false

  alias Mix.Tasks.Perf.ClickHouseHTTP

  def truncate_events!(db_name) do
    ClickHouseHTTP.execute!("TRUNCATE TABLE IF EXISTS #{db_name}.events")
  end

  def seed_sessions!(opts) do
    db_name = Keyword.fetch!(opts, :db_name)
    sessions = Keyword.fetch!(opts, :sessions)
    space_hash = Keyword.fetch!(opts, :space_hash)
    embed_hash = Keyword.fetch!(opts, :embed_hash)

    # Generates 2 rows per session (play + pause) using arrayZip so offsets match names.
    # Spreads timestamps across roughly the last 24h so queries touch a realistic range.
    sql = """
    INSERT INTO #{db_name}.events
    (timestamp, name, session_id, space_hash, embed_hash, video_time, duration, source_url, browser, browser_version, os, os_version, device, device_brand)
    SELECT
      addSeconds(addMilliseconds(now64(6), -toInt64(number % 86400000)), ev.2) AS timestamp,
      ev.1 AS name,
      session_id,
      #{string_lit(space_hash)} AS space_hash,
      #{string_lit(embed_hash)} AS embed_hash,
      if(ev.1 = 'play', 0.0, 2.0) AS video_time,
      10.0 AS duration,
      'https://example.com/watch' AS source_url,
      'Chrome' AS browser,
      '131' AS browser_version,
      'Mac' AS os,
      '14' AS os_version,
      'desktop' AS device,
      'Apple' AS device_brand
    FROM
    (
      SELECT
        generateUUIDv4() AS session_id,
        number
      FROM numbers(#{sessions})
    )
    ARRAY JOIN arrayZip(['play', 'pause'], [0, 2000]) AS ev
    """

    ClickHouseHTTP.execute!(sql)
  end

  defp string_lit(value) do
    escaped =
      value
      |> to_string()
      |> String.replace("\\", "\\\\")
      |> String.replace("'", "\\'")

    "'#{escaped}'"
  end
end
