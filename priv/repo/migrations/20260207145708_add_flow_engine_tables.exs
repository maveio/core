defmodule MaveCore.Repo.Migrations.AddFlowEngineTables do
  use Ecto.Migration

  def change do
    create table(:flow_templates, primary_key: false) do
      add :id, :binary_id, primary_key: true
      add :slug, :string, null: false
      add :name, :string, null: false
      add :description, :string

      timestamps(type: :utc_datetime_usec)
    end

    create unique_index(:flow_templates, [:slug])

    create table(:flow_versions, primary_key: false) do
      add :id, :binary_id, primary_key: true

      add :flow_template_id,
          references(:flow_templates, type: :binary_id, on_delete: :delete_all),
          null: false

      add :version, :integer, null: false
      add :status, :string, null: false, default: "active"
      add :definition, :map, null: false
      add :checksum, :string

      timestamps(type: :utc_datetime_usec)
    end

    create unique_index(:flow_versions, [:flow_template_id, :version])
    create index(:flow_versions, [:flow_template_id, :status])

    create table(:flow_runs, primary_key: false) do
      add :id, :binary_id, primary_key: true

      add :flow_template_id,
          references(:flow_templates, type: :binary_id, on_delete: :restrict),
          null: false

      add :flow_version_id,
          references(:flow_versions, type: :binary_id, on_delete: :restrict),
          null: false

      add :status, :string, null: false, default: "queued"
      add :input, :map, null: false, default: %{}
      add :context, :map, null: false, default: %{}
      add :error, :string
      add :started_at, :utc_datetime_usec
      add :completed_at, :utc_datetime_usec

      timestamps(type: :utc_datetime_usec)
    end

    create index(:flow_runs, [:flow_template_id])
    create index(:flow_runs, [:flow_version_id])
    create index(:flow_runs, [:status])

    create table(:step_runs, primary_key: false) do
      add :id, :binary_id, primary_key: true

      add :flow_run_id, references(:flow_runs, type: :binary_id, on_delete: :delete_all),
        null: false

      add :step_id, :string, null: false
      add :step_type, :string, null: false
      add :status, :string, null: false, default: "queued"
      add :attempt, :integer, null: false, default: 0
      add :input, :map, null: false, default: %{}
      add :output, :map
      add :error, :string
      add :started_at, :utc_datetime_usec
      add :completed_at, :utc_datetime_usec

      timestamps(type: :utc_datetime_usec)
    end

    create unique_index(:step_runs, [:flow_run_id, :step_id])
    create index(:step_runs, [:flow_run_id, :status])

    create table(:artifact_refs, primary_key: false) do
      add :id, :binary_id, primary_key: true

      add :flow_run_id, references(:flow_runs, type: :binary_id, on_delete: :delete_all),
        null: false

      add :producer_step_id, :string, null: false
      add :name, :string, null: false
      add :uri, :string, null: false
      add :media_type, :string
      add :size_bytes, :bigint
      add :metadata, :map, null: false, default: %{}

      timestamps(type: :utc_datetime_usec)
    end

    create unique_index(:artifact_refs, [:flow_run_id, :producer_step_id, :name])
    create index(:artifact_refs, [:flow_run_id])
  end
end
