defmodule MaveCore.Assets.AudioDescription do
  @moduledoc """
  A generated audio-description track of a video in one language: a full-mix MP3
  (the video's audio with spoken descriptions) and the matching descriptions VTT.
  """
  use MaveCore.Schema
  import Ecto.Changeset

  alias MaveCore.Assets.Video

  schema "audio_descriptions" do
    field :language, :string
    field :audio_filename, :string
    field :audio_file_size, :integer
    field :vtt_filename, :string
    field :vtt_file_size, :integer
    field :cue_count, :integer
    field :ducked_cue_count, :integer

    belongs_to :video, Video

    timestamps()
  end

  def changeset(audio_description, attrs) do
    audio_description
    |> cast(attrs, [
      :video_id,
      :language,
      :audio_filename,
      :audio_file_size,
      :vtt_filename,
      :vtt_file_size,
      :cue_count,
      :ducked_cue_count
    ])
    |> validate_required([:video_id, :language, :audio_filename, :vtt_filename])
    |> foreign_key_constraint(:video_id)
    |> unique_constraint([:video_id, :language])
  end

  @doc "HLS playlist of the audio track, relative to the video version's prefix."
  def hls_playlist(%__MODULE__{audio_filename: filename}), do: hls_playlist(filename)

  def hls_playlist(filename) when is_binary(filename) do
    (filename |> Path.basename() |> Path.rootname()) <> "_hls/playlist.m3u8"
  end
end
