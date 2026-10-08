defmodule MaveCore.ClickHouseRepo.Migrations.CreateEvents do
  use Ecto.Migration

  def up do
    create table("events", primary_key: false, engine: "MergeTree", options: "PARTITION BY toYYYYMM(timestamp) ORDER BY (space_hash, embed_hash, session_id, timestamp)") do
      add :timestamp, :"DateTime64(6)"
      add :name, :string
      add :session_id, :uuid
      add :space_hash, :string
      add :embed_hash, :string
      add :video_time, :"Float32"
      add :duration, :"Float32"
      add :source_url, :string
      add :component, :string

      # Session Context
      add :browser, :string
      add :browser_version, :string
      add :os, :string
      add :os_version, :string
      add :device, :string
      add :device_brand, :string
    end
  end

  def down do
    drop table("events")
  end
end
