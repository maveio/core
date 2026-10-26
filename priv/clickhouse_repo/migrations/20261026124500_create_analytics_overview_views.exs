defmodule MaveCore.ClickHouseRepo.Migrations.CreateAnalyticsOverviewViews do
  use Ecto.Migration

  def up do
    execute("""
    CREATE TABLE analytics_overview_views (
      space_hash String, bucket UInt8, generation UUID, session_id UUID,
      embed_hash String, first_at DateTime64(6), last_at DateTime64(6),
      device String, browser String, duration Float64, furthest Float64,
      watch_ms Int64, last_span_end DateTime64(6),
      INDEX first_at_range first_at TYPE minmax GRANULARITY 1,
      INDEX last_at_range last_at TYPE minmax GRANULARITY 1
    ) ENGINE = MergeTree
    PARTITION BY (space_hash, generation)
    ORDER BY (space_hash, bucket, generation, first_at, session_id, embed_hash)
    SETTINGS max_bytes_to_merge_at_max_space_in_pool = 0
    """)
  end

  def down, do: execute("DROP TABLE IF EXISTS analytics_overview_views")
end
