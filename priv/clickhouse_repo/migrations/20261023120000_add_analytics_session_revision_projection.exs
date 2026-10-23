defmodule MaveCore.ClickHouseRepo.Migrations.AddAnalyticsSessionRevisionProjection do
  use Ecto.Migration

  def up do
    # An aggregate inventory does not reorder raw event reads or their ties.
    execute("""
    ALTER TABLE events ADD PROJECTION analytics_session_revisions (
      SELECT space_hash, modulo(cityHash64(session_id), 16) AS bucket, session_id,
        count() AS source_rows,
        sumWithOverflow(cityHash64(timestamp, name, session_id, space_hash, embed_hash,
          video_time, duration, source_url, component, browser, browser_version,
          os, os_version, device, device_brand)) AS fingerprint
      GROUP BY space_hash, bucket, session_id
    )
    """)
  end

  def down do
    execute("ALTER TABLE events DROP PROJECTION IF EXISTS analytics_session_revisions")
  end
end
