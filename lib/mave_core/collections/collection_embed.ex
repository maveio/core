defmodule MaveCore.Collections.CollectionEmbed do
  @moduledoc false
  use MaveCore.Schema
  import Ecto.Changeset

  alias MaveCore.Collections.Collection
  alias MaveCore.Embeds.Embed

  schema "collection_embeds" do
    field :position, :float

    belongs_to :embed, Embed
    belongs_to :collection, Collection

    timestamps()
  end

  def changeset(collection_embed, attrs) do
    collection_embed
    |> cast(attrs, [:embed_id, :collection_id, :position])
    |> validate_required([:embed_id, :collection_id])
    |> foreign_key_constraint(:embed_id)
    |> foreign_key_constraint(:collection_id)
    |> unique_constraint([:collection_id, :embed_id])
  end
end
