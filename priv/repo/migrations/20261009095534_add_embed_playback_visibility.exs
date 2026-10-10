defmodule MaveCore.Repo.Migrations.AddEmbedPlaybackVisibility do
  use Ecto.Migration

  def change do
    alter table(:embeds) do
      add(:playback_visibility, :string, null: false, default: "public")
      add(:playback_status, :string, null: false, default: "public")
    end

    create(
      constraint(:embeds, :embeds_playback_visibility_check,
        check: "playback_visibility IN ('public', 'private')"
      )
    )

    create(
      constraint(:embeds, :embeds_playback_status_check,
        check: "playback_status IN ('public', 'protecting', 'private', 'publishing')"
      )
    )
  end
end
