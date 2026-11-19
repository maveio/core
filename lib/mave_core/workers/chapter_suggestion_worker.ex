defmodule MaveCore.Workers.ChapterSuggestionWorker do
  @moduledoc """
  Suggests chapters for one video version in the background and stores them as
  the draft. Queued after a transcript arrives (for spaces with automatic
  chapters) and when someone asks for a suggestion in the dashboard.
  """
  use Oban.Worker,
    queue: :flow_low,
    max_attempts: 3,
    unique: [
      keys: [:video_id],
      period: :infinity,
      states: [:available, :scheduled, :retryable]
    ]

  alias MaveCore.Chapters
  alias MaveCore.Embeds.Embed
  alias MaveCore.Repo

  @impl true
  def perform(%Oban.Job{args: %{"embed_id" => embed_id, "video_id" => video_id}}) do
    case Repo.get(Embed, embed_id) do
      %Embed{deleted_at: nil} = embed ->
        case Chapters.generate(embed, video_id) do
          {:ok, _set} -> :ok
          {:error, :video_not_found} -> :ok
          {:error, reason} -> {:error, reason}
        end

      _ ->
        :ok
    end
  end
end
