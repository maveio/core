defmodule MaveCore.Assets.Video do
  @moduledoc false
  use MaveCore.Schema
  import Ecto.Changeset

  alias MaveCore.Assets.{Asset, AudioTrack, Rendition, Subtitle}

  schema "videos" do
    field :status, :string
    field :file_name, :string
    field :source_url, :string
    field :max_width, :integer
    field :max_height, :integer
    field :max_frame_rate, :float
    field :max_bitrate, :integer
    field :duration, :float
    field :aspect_ratio, :string
    field :original_file_size, :integer
    field :language, :string

    belongs_to :asset, Asset
    has_many :audio_tracks, AudioTrack
    has_many :renditions, Rendition
    has_many :subtitles, Subtitle

    timestamps()
  end

  def changeset(video, attrs) do
    video
    |> cast(attrs, [
      :asset_id,
      :status,
      :file_name,
      :source_url,
      :max_width,
      :max_height,
      :max_frame_rate,
      :max_bitrate,
      :duration,
      :aspect_ratio,
      :original_file_size,
      :language
    ])
    |> validate_required([:asset_id])
    |> foreign_key_constraint(:asset_id)
  end
end
