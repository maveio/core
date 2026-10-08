defmodule MaveCore.Repo.Migrations.AddFlowDiagnosticsPerformanceIndexes do
  use Ecto.Migration

  @disable_ddl_transaction true
  @disable_migration_lock true

  def change do
    create_if_not_exists index(:flow_runs, [:inserted_at], concurrently: true)
    create_if_not_exists index(:flow_runs, [:status, :inserted_at], concurrently: true)
    create_if_not_exists index(:step_runs, [:inserted_at], concurrently: true)
    create_if_not_exists index(:step_runs, [:step_type, :inserted_at], concurrently: true)
  end
end
