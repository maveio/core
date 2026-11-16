defmodule MaveCore.ClickHouseRepo.Migrations.CreatePlaybackPerformance do
  use Ecto.Migration

  def up do
    execute("""
    CREATE TABLE IF NOT EXISTS playback_quality (
      timestamp DateTime64(6),
      name LowCardinality(String),
      session_id UUID,
      space_hash String,
      embed_hash String,
      startup_ms UInt32,
      rebuffer_ms UInt32,
      playing_ms UInt32,
      bitrate UInt32,
      width UInt16,
      height UInt16,
      error_code LowCardinality(String),
      browser LowCardinality(String),
      os LowCardinality(String),
      device LowCardinality(String),
      country LowCardinality(String)
    ) ENGINE = MergeTree
    PARTITION BY toYYYYMM(timestamp)
    ORDER BY (space_hash, embed_hash, session_id, timestamp)
    TTL toDateTime(timestamp) + INTERVAL 13 MONTH
    """)

    execute("""
    CREATE TABLE IF NOT EXISTS cdn_requests (
      timestamp DateTime64(6),
      space_hash String,
      embed_hash String,
      status UInt16,
      cache_status LowCardinality(String),
      origin UInt8,
      bytes UInt64,
      ttfb_ms UInt32,
      country LowCardinality(String),
      pop LowCardinality(String)
    ) ENGINE = MergeTree
    PARTITION BY toYYYYMM(timestamp)
    ORDER BY (space_hash, embed_hash, timestamp)
    TTL toDateTime(timestamp) + INTERVAL 13 MONTH
    """)
  end

  def down do
    execute("DROP TABLE IF EXISTS cdn_requests")
    execute("DROP TABLE IF EXISTS playback_quality")
  end
end
