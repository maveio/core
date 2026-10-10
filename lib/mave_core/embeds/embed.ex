defmodule MaveCore.Embeds.Embed do
  @moduledoc false
  use MaveCore.Schema
  import Ecto.Changeset

  alias MaveCore.Assets.Asset
  alias MaveCore.Collections.Collection
  alias MaveCore.Collections.CollectionEmbed
  alias MaveCore.Embeds.EmbedSettings
  alias MaveCore.Spaces.Space

  schema "embeds" do
    field :hash, :string
    field :type, Ecto.Enum, values: [:video, :collection], default: :video
    field :version, :integer, default: 1
    field :external_url, :string
    field :archived, :boolean, default: false
    field :replacing, :boolean, default: false
    # Last visibility confirmed by storage synchronization.
    field :playback_visibility, Ecto.Enum, values: [:public, :private], default: :public

    field :playback_status, Ecto.Enum,
      values: [:public, :protecting, :private, :publishing],
      default: :public

    field :deleted_at, :utc_datetime_usec

    belongs_to :space, Space
    belongs_to :asset, Asset
    belongs_to :settings, EmbedSettings, foreign_key: :embed_settings_id
    belongs_to :collection, Collection

    has_many :collection_embeds, CollectionEmbed

    timestamps()
  end

  def changeset(embed, attrs) do
    embed
    |> cast(attrs, [
      :hash,
      :type,
      :version,
      :external_url,
      :archived,
      :replacing,
      :deleted_at,
      :space_id,
      :asset_id,
      :embed_settings_id,
      :collection_id
    ])
    |> validate_required([:hash, :space_id, :type])
    |> unique_constraint(:hash)
    |> foreign_key_constraint(:space_id)
    |> foreign_key_constraint(:asset_id)
    |> foreign_key_constraint(:embed_settings_id)
    |> foreign_key_constraint(:collection_id)
  end
end
