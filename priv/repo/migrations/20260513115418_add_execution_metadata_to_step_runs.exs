defmodule MaveCore.Repo.Migrations.AddExecutionMetadataToStepRuns do
  use Ecto.Migration

  def change do
    alter table(:step_runs) do
      add :execution_metadata, :map, null: false, default: %{}
    end
  end
end
