defmodule MaveCore.Assets.Rendition do
  @moduledoc false
  use MaveCore.Schema
  import Ecto.Changeset

  alias MaveCore.Assets.Video

  @types [
    :audio,
    :video,
    :poster,
    :thumbnail,
    :placeholder,
    :storyboard,
    :segments,
    :clip_keyframes,
    :clip,
    :custom_thumbnail
  ]

  @codecs [:webp, :webm, :jpg, :h264, :hevc, :av1, :mp3, :aac]
  @containers [:webp, :webm, :jpg, :mp4, :avif, :hls, :mp3]
  @sizes [:sd, :hd, :fhd, :qhd, :uhd]

  schema "renditions" do
    field :rendition_key, :string
    field :type, Ecto.Enum, values: @types
    field :codec, Ecto.Enum, values: @codecs
    field :container, Ecto.Enum, values: @containers
    field :size, Ecto.Enum, values: @sizes
    field :progress, :float
    field :file_size, :integer

    belongs_to :video, Video

    timestamps()
  end

  def changeset(rendition, attrs) do
    rendition
    |> cast(attrs, [
      :video_id,
      :rendition_key,
      :type,
      :codec,
      :container,
      :size,
      :progress,
      :file_size
    ])
    |> validate_required([:video_id, :rendition_key, :type])
    |> foreign_key_constraint(:video_id)
    |> unique_constraint(:rendition_key)
  end
end
