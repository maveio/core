defmodule MaveCore.Repo.Migrations.CreateLiveStreams do
  use Ecto.Migration

  def change do
    create table(:live_streams, primary_key: false) do
      add :id, :binary_id, primary_key: true
      add :space_id, references(:spaces, type: :binary_id, on_delete: :delete_all), null: false
      add :hash, :string, null: false
      add :name, :string
      add :stream_key, :string, null: false
      add :status, :string, null: false, default: "idle"
      add :broadcast, :integer, null: false, default: 0
      add :target_duration, :integer
      add :ingest, :map
      add :last_error, :string
      add :started_at, :utc_datetime_usec
      add :disconnected_at, :utc_datetime_usec
      add :ended_at, :utc_datetime_usec
      add :heartbeat_at, :utc_datetime_usec

      timestamps(type: :utc_datetime_usec)
    end

    create unique_index(:live_streams, [:hash])
    create unique_index(:live_streams, [:stream_key])
    create index(:live_streams, [:space_id, :inserted_at])
    create index(:live_streams, [:status], where: "status IN ('live', 'disconnected')")

    create constraint(:live_streams, :live_streams_status_check,
             check: "status IN ('idle', 'live', 'disconnected', 'ended')"
           )

    create table(:live_stream_segments, primary_key: false) do
      add :live_stream_id,
          references(:live_streams, type: :binary_id, on_delete: :delete_all),
          primary_key: true

      add :sequence, :bigint, primary_key: true
      add :broadcast, :integer, null: false
      add :duration, :float, null: false
      add :key, :string, null: false
      add :size_bytes, :bigint
      add :discontinuity, :boolean, null: false, default: false
      add :discontinuity_sequence, :integer, null: false, default: 0
      add :program_date_time, :utc_datetime_usec

      timestamps(type: :utc_datetime_usec, updated_at: false)
    end
  end
end
