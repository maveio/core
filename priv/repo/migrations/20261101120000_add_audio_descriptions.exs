defmodule MaveCore.Repo.Migrations.AddAudioDescriptions do
  use Ecto.Migration

  def change do
    alter table(:spaces) do
      add :audio_description_enabled, :boolean, null: false, default: false
    end

    create table(:audio_descriptions, primary_key: false) do
      add :id, :binary_id, primary_key: true
      add :video_id, references(:videos, type: :binary_id, on_delete: :delete_all), null: false
      add :language, :language_code, null: false
      add :audio_filename, :string, null: false
      add :audio_file_size, :bigint
      add :vtt_filename, :string, null: false
      add :vtt_file_size, :bigint
      add :cue_count, :integer
      add :ducked_cue_count, :integer

      timestamps(type: :utc_datetime_usec)
    end

    create unique_index(:audio_descriptions, [:video_id, :language])
  end
end
