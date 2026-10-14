defmodule MaveCore.Repo.Migrations.AddEmbedPlaybackPassword do
  use Ecto.Migration

  def change do
    alter table(:embeds) do
      add :password_hash, :text
      add :password_revision, :bigint, null: false, default: 0
    end
  end
end
