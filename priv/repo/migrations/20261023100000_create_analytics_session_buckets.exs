defmodule MaveCore.Repo.Migrations.CreateAnalyticsSessionBuckets do
  use Ecto.Migration

  def change do
    create table(:analytics_session_buckets, primary_key: false) do
      add(:space_hash, :text, primary_key: true)
      add(:bucket, :integer, primary_key: true)
      add(:generation, :uuid, null: false)
      add(:source_rows, :bigint, null: false)
      add(:fingerprint, :text, null: false)
      add(:format_version, :integer, null: false)
      add(:refresh_after, :utc_datetime_usec)
      add(:latest_event_at, :utc_datetime_usec)
      add(:last_cleanup_at, :utc_datetime_usec)
      add(:updated_at, :utc_datetime_usec, null: false)
    end
  end
end
