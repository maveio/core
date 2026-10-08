defmodule MaveCore.Assets.Subtitle do
  @moduledoc false
  use MaveCore.Schema
  import Ecto.Changeset

  alias MaveCore.Assets.Video

  schema "subtitles" do
    field :path, :string
    field :language, :string

    belongs_to :video, Video

    timestamps()
  end

  def changeset(subtitle, attrs) do
    subtitle
    |> cast(attrs, [:video_id, :language, :path])
    |> validate_required([:video_id])
    |> foreign_key_constraint(:video_id)
  end
end
