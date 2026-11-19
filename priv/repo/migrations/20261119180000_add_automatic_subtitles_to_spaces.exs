defmodule MaveCore.Repo.Migrations.AddAutomaticSubtitlesToSpaces do
  use Ecto.Migration

  def change do
    alter table(:spaces) do
      add :automatic_subtitles_enabled, :boolean, null: false, default: true
    end
  end
end
