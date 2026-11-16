defmodule MaveCore.Repo.Migrations.CreateFlowPipelineVersions do
  use Ecto.Migration

  def change do
    create table(:flow_pipeline_versions, primary_key: false) do
      add :id, :binary_id, primary_key: true
      add :space_id, references(:spaces, type: :binary_id, on_delete: :delete_all), null: false
      add :created_by_id, references(:users, type: :binary_id, on_delete: :nilify_all)
      add :version, :integer, null: false
      add :overrides, :map, null: false, default: %{}
      add :note, :string

      timestamps(type: :utc_datetime_usec, updated_at: false)
    end

    create unique_index(:flow_pipeline_versions, [:space_id, :version])
  end
end
