defmodule MaveCore.Repo.Migrations.AddSubtitleSource do
  use Ecto.Migration

  def change do
    alter table(:subtitles) do
      add :source, :string
    end
  end
end
