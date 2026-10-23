defmodule MaveCore.ClickHouseRepo.Migrations.CreateAnalyticsSessions do
  use Ecto.Migration

  def up do
    # Generations are written once and retired as complete partitions; merging
    # their parts spends memory/IO without improving update correctness.
    execute("""
    CREATE TABLE analytics_sessions (
      space_hash String, bucket UInt8, generation UUID, session_id UUID,
      source_rows UInt64, fingerprint UInt64,
      events Array(Tuple(String, DateTime64(6), String, Float64, Float64, String, String, String, String)),
      segments Array(Tuple(String, DateTime64(6), DateTime64(6), Float64, Float64, Float64)),
      created_at DateTime64(6)
    ) ENGINE = MergeTree
    PARTITION BY (space_hash, generation)
    ORDER BY (space_hash, bucket, generation, session_id)
    SETTINGS max_bytes_to_merge_at_max_space_in_pool = 0
    """)

    execute("""
    CREATE TABLE analytics_session_years (
      space_hash String, bucket UInt8, generation UUID, session_id UUID, year UInt16,
      first_at DateTime64(6), source_device String, source_browser String,
      watched Int64, days Array(Tuple(Date, Int64)), created_at DateTime64(6),
      unique_intervals Array(Tuple(Date, UInt64, UInt64))
    ) ENGINE = MergeTree PARTITION BY (space_hash, generation) ORDER BY (space_hash, bucket, generation, year, session_id)
    SETTINGS max_bytes_to_merge_at_max_space_in_pool = 0
    """)

    # Existing parts may be materialized separately; correctness does not depend
    # on the projection being present in every part. Never backfill during deploy.
    execute("""
    ALTER TABLE events ADD PROJECTION analytics_session_inventory (
      SELECT space_hash, modulo(cityHash64(session_id), 16) AS bucket,
        count() AS source_rows,
        sumWithOverflow(cityHash64(timestamp, name, session_id, space_hash, embed_hash,
          video_time, duration, source_url, component, browser, browser_version,
          os, os_version, device, device_brand)) AS fingerprint
      GROUP BY space_hash, bucket
    )
    """)
  end

  def down do
    execute("ALTER TABLE events DROP PROJECTION IF EXISTS analytics_session_inventory")
    execute("DROP TABLE IF EXISTS analytics_sessions")
    execute("DROP TABLE IF EXISTS analytics_session_years")
  end
end
