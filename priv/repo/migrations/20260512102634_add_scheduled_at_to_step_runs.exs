defmodule MaveCore.Repo.Migrations.AddScheduledAtToStepRuns do
  use Ecto.Migration

  def change do
    alter table(:step_runs) do
      add :scheduled_at, :utc_datetime_usec
    end
  end
end
