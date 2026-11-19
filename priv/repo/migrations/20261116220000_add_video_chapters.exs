defmodule MaveCore.Repo.Migrations.AddVideoChapters do
  use Ecto.Migration

  def change do
    alter table(:spaces) do
      add :automatic_chapters_enabled, :boolean, null: false, default: false
    end

    create table(:chapter_sets, primary_key: false) do
      add :id, :binary_id, primary_key: true
      add :video_id, references(:videos, type: :binary_id, on_delete: :delete_all), null: false
      add :status, :string, null: false, default: "idle"
      add :reason, :string
      add :generator, :string
      add :inputs, {:array, :string}, null: false, default: []
      add :language, :string
      add :draft, {:array, :map}, null: false, default: []
      add :published, {:array, :map}, null: false, default: []
      add :generated_at, :utc_datetime_usec
      add :published_at, :utc_datetime_usec

      timestamps(type: :utc_datetime_usec)
    end

    create unique_index(:chapter_sets, [:video_id])
  end
end
