defmodule MaveCore.Assets.Asset do
  @moduledoc false
  use MaveCore.Schema
  import Ecto.Changeset

  alias MaveCore.Assets.Video
  alias MaveCore.Spaces.Space

  schema "assets" do
    field :name, :string

    belongs_to :space, Space
    belongs_to :current_video, Video

    has_many :videos, Video

    timestamps()
  end

  def changeset(asset, attrs) do
    asset
    |> cast(attrs, [:name, :space_id, :current_video_id])
    |> validate_required([:space_id])
    |> foreign_key_constraint(:space_id)
    |> foreign_key_constraint(:current_video_id)
  end
end
