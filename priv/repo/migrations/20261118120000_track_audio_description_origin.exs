defmodule MaveCore.Repo.Migrations.TrackAudioDescriptionOrigin do
  use Ecto.Migration

  def up do
    alter table(:audio_descriptions) do
      add :audio_origin, :string, null: false, default: "generated"
    end

    # The upload handler assigns this prefix even when replacing a generated
    # track. A renamed or editor-rendered generated track keeps its own filename.
    execute """
    UPDATE audio_descriptions SET audio_origin = 'uploaded'
    WHERE starts_with(audio_filename, 'audio_description_upload_')
    """
  end

  def down do
    alter table(:audio_descriptions) do
      remove :audio_origin
    end
  end
end
