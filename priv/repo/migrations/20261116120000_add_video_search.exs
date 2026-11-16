defmodule MaveCore.Repo.Migrations.AddVideoSearch do
  use Ecto.Migration

  def up do
    alter table(:spaces) do
      add :video_search_enabled, :boolean, null: false, default: false
    end

    create table(:video_search_moments, primary_key: false) do
      add :id, :binary_id, primary_key: true
      add :space_id, references(:spaces, type: :binary_id, on_delete: :delete_all), null: false
      add :video_id, references(:videos, type: :binary_id, on_delete: :delete_all), null: false
      add :source, :string, null: false
      add :start_ms, :integer, null: false
      add :end_ms, :integer, null: false
      add :text, :text, null: false
      add :language, :string
      # Built from text that Core normalizes (case, accents, word boundaries)
      # exactly like queries. The `simple` configuration keeps the index
      # language-neutral: one space can hold videos in several languages.
      add :search_vector, :tsvector, null: false

      timestamps(type: :utc_datetime_usec, updated_at: false)
    end

    create constraint(:video_search_moments, :video_search_moments_source_check,
             check: "source IN ('visual', 'transcript')"
           )

    create index(:video_search_moments, [:video_id])
    create index(:video_search_moments, [:space_id])
    create index(:video_search_moments, [:search_vector], using: :gin)
  end

  def down do
    drop table(:video_search_moments)

    alter table(:spaces) do
      remove :video_search_enabled
    end
  end
end
