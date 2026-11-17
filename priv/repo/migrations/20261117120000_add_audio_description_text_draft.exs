defmodule MaveCore.Repo.Migrations.AddAudioDescriptionTextDraft do
  use Ecto.Migration

  def change do
    alter table(:audio_descriptions) do
      add :text_draft, :map
    end
  end
end
