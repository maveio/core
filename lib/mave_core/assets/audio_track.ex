defmodule MaveCore.Assets.AudioTrack do
  @moduledoc false
  use MaveCore.Schema
  import Ecto.Changeset

  alias MaveCore.Assets.Video

  @codec_values ~w(aac flac mp3 ogg wav)

  schema "audio_tracks" do
    field :label, :string
    field :language, :string
    field :default, :boolean, default: false
    field :codec, :string
    field :file_size, :integer
    field :filename, :string

    belongs_to :video, Video

    timestamps()
  end

  @doc "Uses the configured label, or identifies the original audio by its known language."
  def display_label(track) do
    label = Map.get(track, :label, Map.get(track, "label"))
    language = Map.get(track, :language, Map.get(track, "language"))
    default? = Map.get(track, :default, Map.get(track, "default")) in [true, "true", 1, "1"]

    name =
      language
      |> MaveCore.Languages.normalize_media_language()
      |> MaveCore.Languages.spoken_language()

    if default? and label in [nil, "", "Original"] do
      if name, do: "#{name} (original)", else: "Original"
    else
      if label in [nil, ""], do: "Audio track", else: label
    end
  end

  def changeset(audio_track, attrs) do
    audio_track
    |> cast(attrs, [:video_id, :label, :language, :default, :codec, :file_size, :filename])
    |> validate_required([:video_id, :filename])
    |> validate_inclusion(:codec, @codec_values, allow_nil: true, message: "is not supported")
    |> foreign_key_constraint(:video_id)
    |> unique_constraint([:video_id, :filename])
  end
end
