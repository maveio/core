defmodule MaveCore.Repo.Migrations.AddMultiRegionDelivery do
  use Ecto.Migration

  def change do
    alter table(:spaces) do
      # Storage profile names, not the legacy `region` enum: replicas may use any
      # profile configured by the host.
      add :replica_regions, {:array, :string}, null: false, default: []
      add :delivery_region, :string
      add :delivery_failover, :string, null: false, default: "automatic"
      add :delivery_region_reason, :string
      add :delivery_region_changed_at, :utc_datetime_usec
    end

    create table(:space_region_states, primary_key: false) do
      add :id, :binary_id, primary_key: true
      add :space_id, references(:spaces, type: :binary_id, on_delete: :delete_all), null: false
      add :region, :string, null: false

      add :health, :string, null: false, default: "unknown"
      add :health_error, :string
      add :health_checked_at, :utc_datetime_usec
      add :health_changed_at, :utc_datetime_usec
      add :consecutive_successes, :integer, null: false, default: 0

      add :sync_status, :string, null: false, default: "pending"
      add :sync_error, :string
      add :sync_started_at, :utc_datetime_usec
      add :synced_at, :utc_datetime_usec
      add :objects_total, :integer, null: false, default: 0
      add :bytes_total, :bigint, null: false, default: 0
      add :objects_pending, :integer, null: false, default: 0
      add :last_copied, :integer, null: false, default: 0
      add :last_deleted, :integer, null: false, default: 0

      timestamps(type: :utc_datetime_usec)
    end

    create unique_index(:space_region_states, [:space_id, :region])
  end
end
