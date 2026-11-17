defmodule MaveCore.Repo.Migrations.CreateExperiments do
  use Ecto.Migration

  def change do
    create table(:experiments, primary_key: false) do
      add :id, :binary_id, primary_key: true
      add :space_id, references(:spaces, type: :binary_id, on_delete: :delete_all), null: false
      add :embed_id, references(:embeds, type: :binary_id, on_delete: :delete_all), null: false
      add :status, :string, null: false, default: "running"
      add :metric, :string, null: false
      add :duration_days, :integer, null: false
      add :min_views, :integer, null: false
      add :started_at, :utc_datetime_usec, null: false
      add :ends_at, :utc_datetime_usec, null: false
      add :ended_at, :utc_datetime_usec
      add :decided_by, :string
      add :outcome_reason, :string
      add :results, :map

      timestamps(type: :utc_datetime_usec)
    end

    create table(:experiment_variants, primary_key: false) do
      add :id, :binary_id, primary_key: true

      add :experiment_id, references(:experiments, type: :binary_id, on_delete: :delete_all),
        null: false

      add :embed_id, references(:embeds, type: :binary_id, on_delete: :delete_all), null: false
      add :position, :integer, null: false

      timestamps(type: :utc_datetime_usec)
    end

    alter table(:experiments) do
      add :winner_variant_id,
          references(:experiment_variants, type: :binary_id, on_delete: :nilify_all)
    end

    create index(:experiments, [:space_id])
    create index(:experiments, [:status, :ends_at])

    # An embed serves at most one test at a time. A locked test still decides
    # what the embed plays, so it counts until the lock is removed.
    create unique_index(:experiments, [:embed_id],
             where: "status IN ('running', 'needs_decision', 'locked')",
             name: :experiments_active_embed_index
           )

    create unique_index(:experiment_variants, [:experiment_id, :embed_id])
    create unique_index(:experiment_variants, [:experiment_id, :position])
    create index(:experiment_variants, [:embed_id])
  end
end
