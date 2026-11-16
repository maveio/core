defmodule MaveCore.Assets.ChapterSet do
  @moduledoc """
  The chapters of one video version.

  `draft` holds the chapters under review: suggestions, manual edits, or both.
  `published` is the copy viewers get; it only changes when a person publishes.
  Both are ordered lists of `%{"start" => seconds, "title" => text}`.
  """
  use MaveCore.Schema
  import Ecto.Changeset

  alias MaveCore.Assets.Video

  @statuses ~w(idle generating failed)
  @max_chapters 100
  @max_title_length 120

  schema "chapter_sets" do
    field :status, :string, default: "idle"
    field :reason, :string
    field :generator, :string
    field :inputs, {:array, :string}, default: []
    field :language, :string
    field :draft, {:array, :map}, default: []
    field :published, {:array, :map}, default: []
    field :generated_at, :utc_datetime_usec
    field :published_at, :utc_datetime_usec

    belongs_to :video, Video

    timestamps()
  end

  def max_chapters, do: @max_chapters
  def max_title_length, do: @max_title_length

  def changeset(chapter_set, attrs) do
    chapter_set
    |> cast(attrs, [
      :video_id,
      :status,
      :reason,
      :generator,
      :inputs,
      :language,
      :draft,
      :published,
      :generated_at,
      :published_at
    ])
    |> validate_required([:video_id, :status])
    |> validate_inclusion(:status, @statuses)
    |> validate_chapters(:draft)
    |> validate_chapters(:published)
    |> foreign_key_constraint(:video_id)
    |> unique_constraint(:video_id)
  end

  defp validate_chapters(changeset, field) do
    validate_change(changeset, field, fn ^field, chapters ->
      cond do
        length(chapters) > @max_chapters -> [{field, "has too many chapters"}]
        not Enum.all?(chapters, &valid_chapter?/1) -> [{field, "has an invalid chapter"}]
        not ascending?(chapters) -> [{field, "must be ordered by unique start times"}]
        true -> []
      end
    end)
  end

  defp valid_chapter?(%{"start" => start, "title" => title})
       when is_number(start) and start >= 0 and is_binary(title) do
    title != "" and String.length(title) <= @max_title_length
  end

  defp valid_chapter?(_chapter), do: false

  defp ascending?(chapters) do
    chapters
    |> Enum.map(& &1["start"])
    |> Enum.chunk_every(2, 1, :discard)
    |> Enum.all?(fn [left, right] -> left < right end)
  end
end
