defmodule MaveCore.ClickHouseRepo.Migrations.CreateAnalyticsSessionReports do
  use Ecto.Migration

  def up do
    execute("""
    CREATE TABLE analytics_session_reports (
      space_hash String, bucket UInt8, generation UUID, session_id UUID,
      complete UInt8, days Array(Tuple(String, Date, Int64, Nullable(Float64)))
    ) ENGINE = MergeTree
    PARTITION BY (space_hash, generation)
    ORDER BY (space_hash, bucket, generation, session_id)
    SETTINGS max_bytes_to_merge_at_max_space_in_pool = 0
    """)
  end

  def down, do: execute("DROP TABLE IF EXISTS analytics_session_reports")
end
