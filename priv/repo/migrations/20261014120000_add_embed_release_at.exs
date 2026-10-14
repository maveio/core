defmodule MaveCore.Repo.Migrations.AddEmbedReleaseAt do
  use Ecto.Migration

  def change do
    alter table(:embeds) do
      # Non-null while a scheduled release is pending; cleared once storage
      # confirms public playback after the release time.
      add(:release_at, :utc_datetime_usec)
    end

    create(index(:embeds, [:release_at], where: "release_at IS NOT NULL"))
  end
end
