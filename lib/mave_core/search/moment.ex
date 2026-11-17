defmodule MaveCore.Search.Moment do
  @moduledoc """
  One searchable moment of a video version: what is visible on screen around a
  timestamp (`visual`) or what is said in one transcript cue (`transcript`).
  """
  use MaveCore.Schema

  alias MaveCore.Assets.Video
  alias MaveCore.Spaces.Space

  @sources ~w(visual transcript)

  schema "video_search_moments" do
    field :source, :string
    field :start_ms, :integer
    field :end_ms, :integer
    field :text, :string
    field :language, :string
    # Written by `MaveCore.Search.index_video/4` and only used inside queries.
    field :search_vector, :string, load_in_query: false, writable: :never

    belongs_to :space, Space
    belongs_to :video, Video

    timestamps(updated_at: false)
  end

  def sources, do: @sources
end
