defmodule MaveCore.Repo.Migrations.CreateAnalyticsSessionRetirements do
  use Ecto.Migration

  def change do
    create table(:analytics_session_retirements, primary_key: false) do
      add(:space_hash, :text, primary_key: true)
      add(:generation, :uuid, primary_key: true)
      add(:retired_at, :utc_datetime_usec, null: false)
    end

    create(index(:analytics_session_retirements, [:retired_at]))
  end
end
