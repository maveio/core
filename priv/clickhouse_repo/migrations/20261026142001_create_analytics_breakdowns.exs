defmodule MaveCore.ClickHouseRepo.Migrations.CreateAnalyticsBreakdowns do
  use Ecto.Migration

  def up do
    execute("""
    CREATE TABLE IF NOT EXISTS analytics_breakdown_days (
      space_hash String, bucket UInt8, generation UUID, session_id UUID,
      embed_hash String, day Date,
      first_at DateTime64(6), last_at DateTime64(6),
      device String, browser String, duration Float64, furthest Float64,
      watch_ms Int64, last_span_end DateTime64(6),
      events Array(Tuple(DateTime64(6), String, Float64, Float64, String, String, String, String)),
      spans Array(Tuple(DateTime64(6), DateTime64(6)))
    ) ENGINE = MergeTree
    PARTITION BY (space_hash, generation)
    ORDER BY (space_hash, bucket, generation, day, session_id, embed_hash)
    SETTINGS max_bytes_to_merge_at_max_space_in_pool = 0
    """)

    execute("""
    CREATE TABLE IF NOT EXISTS analytics_breakdown_views (
      space_hash String, bucket UInt8, generation UUID, session_id UUID,
      embed_hash String, first_at DateTime64(6), last_at DateTime64(6),
      device String, browser String, duration Float64, furthest Float64,
      watch_ms Int64, last_span_end DateTime64(6), os String, website String,
      INDEX first_at_range first_at TYPE minmax GRANULARITY 1,
      INDEX last_at_range last_at TYPE minmax GRANULARITY 1
    ) ENGINE = MergeTree
    PARTITION BY (space_hash, generation)
    ORDER BY (space_hash, bucket, generation, first_at, session_id, embed_hash)
    SETTINGS max_bytes_to_merge_at_max_space_in_pool = 0
    """)
  end

  def down do
    execute("DROP TABLE IF EXISTS analytics_breakdown_views")
    execute("DROP TABLE IF EXISTS analytics_breakdown_days")
  end
end
