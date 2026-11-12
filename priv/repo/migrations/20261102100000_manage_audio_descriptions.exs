defmodule MaveCore.Repo.Migrations.ManageAudioDescriptions do
  use Ecto.Migration

  def up do
    alter table(:audio_descriptions) do
      add :label, :string
      add :generation_language, :language_code
      add :user_managed, :boolean, null: false, default: false
      add :deleted_at, :utc_datetime_usec
      modify :vtt_filename, :string, null: true
    end

    execute "UPDATE audio_descriptions SET generation_language = language"
    drop unique_index(:audio_descriptions, [:video_id, :language])
    create unique_index(:audio_descriptions, [:video_id, :generation_language])
  end

  def down do
    drop unique_index(:audio_descriptions, [:video_id, :generation_language])

    # User-uploaded tracks may share a language or have no VTT. They cannot be
    # represented by the previous schema, so require an explicit data migration.
    create unique_index(:audio_descriptions, [:video_id, :language])

    alter table(:audio_descriptions) do
      modify :vtt_filename, :string, null: false
      remove :deleted_at
      remove :user_managed
      remove :generation_language
      remove :label
    end
  end
end
