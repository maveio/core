defmodule MaveCore.Repo.Migrations.AddSubtitleVocabularyToSpaces do
  use Ecto.Migration

  def change do
    alter table(:spaces) do
      add :subtitle_vocabulary, {:array, :text}, null: false, default: []
    end
  end
end
