defmodule MaveCore.Workers.PlaybackVisibilityWorker do
  @moduledoc false
  use Oban.Worker, queue: :flow_low, max_attempts: 10

  import Ecto.Query
  alias MaveCore.Embeds.Embed
  alias MaveCore.Embeds.Events
  alias MaveCore.Playback
  alias MaveCore.Repo
  alias MaveCore.Spaces.Space

  @impl true
  def perform(%Oban.Job{args: %{"embed_id" => id}}) do
    case Repo.get(Embed, id) do
      %Embed{deleted_at: nil} = embed -> synchronize(embed)
      _ -> :ok
    end
  end

  defp synchronize(embed) do
    Repo.transaction(fn ->
      Repo.one!(from(s in Space, where: s.id == ^embed.space_id, lock: "FOR UPDATE"))
      current = Repo.get!(Embed, embed.id) |> Repo.preload(:space)

      apply_visibility(current, Playback.adapter())
    end)
    |> case do
      {:ok, updated} ->
        Events.broadcast_updated(updated.space_id, updated.id)
        :ok

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp apply_visibility(_embed, nil), do: Repo.rollback(:playback_adapter_missing)

  defp apply_visibility(embed, adapter) do
    case adapter.apply_visibility(embed, embed.playback_visibility) do
      :ok ->
        embed
        |> Ecto.Changeset.change(playback_status: embed.playback_visibility)
        |> Repo.update!()

      {:error, _reason} ->
        Repo.rollback(:playback_storage_sync_failed)
    end
  end
end
