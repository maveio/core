defmodule MaveCore.Workers.PlaybackVisibilityWorker do
  @moduledoc false
  use Oban.Worker, queue: :flow_low, max_attempts: 10

  import Ecto.Query
  alias MaveCore.Embeds.Embed
  alias MaveCore.Embeds.Events
  alias MaveCore.MultiRegion.Replicator
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

      if is_nil(current.deleted_at) and is_nil(current.space.deleted_at) do
        apply_visibility(current, Playback.adapter())
      else
        current
      end
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
    visibility = if embed.playback_status in [:private, :protecting], do: :private, else: :public

    # Replicas only hold public media. Remove this embed's copy before the
    # adapter confirms private visibility, so no region keeps serving it.
    with :ok <- remove_private_replicas(embed, visibility),
         :ok <- adapter.apply_visibility(embed, visibility) do
      embed
      |> Ecto.Changeset.change(playback_visibility: visibility, playback_status: visibility)
      |> Repo.update!()
    else
      {:error, _reason} -> Repo.rollback(:playback_storage_sync_failed)
    end
  end

  defp remove_private_replicas(embed, :private),
    do: Replicator.remove_embed(embed.space, embed.hash)

  defp remove_private_replicas(_embed, :public), do: :ok
end
