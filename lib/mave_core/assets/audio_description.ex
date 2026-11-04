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
    field :label, :string
    field :generation_language, :string
    field :user_managed, :boolean, default: false
    field :deleted_at, :utc_datetime_usec
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
      :label,
      :generation_language,
      :user_managed,
      :deleted_at,
      :audio_filename,
      :audio_file_size,
      :vtt_filename,
      :vtt_file_size,
      :cue_count,
      :ducked_cue_count
    ])
    |> validate_required([:video_id, :language, :audio_filename])
    |> validate_format(:language, ~r/^[a-z]{2,3}(?:-[A-Za-z0-9]{2,8})*$/)
    |> foreign_key_constraint(:video_id)
    |> unique_constraint([:video_id, :generation_language])
  end

  def display_label(%__MODULE__{} = description) do
    name =
      description.label || MaveCore.Languages.spoken_language(description.language) ||
        String.upcase(description.language)

    "#{name} (audio description)"
  end

  @doc "HLS playlist of the audio track, relative to the video version's prefix."
  def hls_playlist(%__MODULE__{audio_filename: filename}), do: hls_playlist(filename)

  def hls_playlist(filename) when is_binary(filename) do
    (filename |> Path.basename() |> Path.rootname()) <> "_hls/playlist.m3u8"
  end
end
