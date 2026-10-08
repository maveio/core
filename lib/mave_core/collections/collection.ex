defmodule MaveCore.Collections.Collection do
  @moduledoc false
  use MaveCore.Schema
  import Ecto.Changeset

  alias MaveCore.Collections.CollectionEmbed
  alias MaveCore.Embeds.Embed
  alias MaveCore.Spaces.Space

  schema "collections" do
    field :name, :string
    field :type, Ecto.Enum, values: [:folder, :showcase], default: :folder

    belongs_to :space, Space

    has_many :collection_embeds, CollectionEmbed
    has_many :embeds, through: [:collection_embeds, :embed]
    has_many :parent_embeds, Embed

    timestamps()
  end

  def changeset(collection, attrs) do
    collection
    |> cast(attrs, [:space_id, :name, :type])
    |> foreign_key_constraint(:space_id)
  end
end
