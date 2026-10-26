defmodule MaveCore.Repo.Migrations.AddOverviewPreparationState do
  use Ecto.Migration

  def change do
    alter table(:analytics_session_buckets) do
      add :overview_ready, :boolean, default: false, null: false
    end
  end
end
