defmodule MaveCore.Repo.Migrations.AddBreakdownPreparationGeneration do
  use Ecto.Migration

  def change do
    alter table(:analytics_session_buckets) do
      add :breakdown_generation, :uuid
    end
  end
end
