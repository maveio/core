defmodule MaveCore.Workers.AccountDeletionWorker do
  @moduledoc "Protects deleted account media in resumable batches without holding database locks."
  use Oban.Worker, queue: :flow_low, max_attempts: 20

  import Ecto.Query
  alias MaveCore.Embeds.Embed
  alias MaveCore.Flow
  alias MaveCore.Media.Storage
  alias MaveCore.Repo
  alias MaveCore.Spaces
  alias MaveCore.Spaces.Space

  @batch_size 20

  @impl true
  def timeout(_job), do: :timer.minutes(5)

  @impl true
  def perform(%Oban.Job{args: %{"space_id" => space_id} = args} = job) do
    case Repo.get(Space, space_id) do
      %Space{deleted_at: deleted_at} = space when not is_nil(deleted_at) ->
        if space.hash == args["space_hash"] and space.region == args["space_region"] do
          protect_batch(space, Map.get(args, "cursor"), job)
        else
          {:cancel, :space_storage_changed}
        end

      _ ->
        {:cancel, :space_not_deleted}
    end
  end

  defp protect_batch(space, cursor, job) do
    query = from(e in Embed, where: e.space_id == ^space.id and e.type == :video)
    query = if cursor, do: where(query, [e], e.id > ^cursor), else: query
    embeds = Repo.all(from(e in query, order_by: e.id, limit: @batch_size))

    result =
      Enum.reduce_while(embeds, :ok, fn embed, :ok ->
        storage = Application.get_env(:mave_core, :storage_module, Storage)

        with {:ok, _} <- Flow.cancel_runs_for_embed(space.hash, embed.hash),
             :ok <- storage.update_embed_visibility(space, embed.hash, "private", space.region),
             {:ok, _} <- save_progress(job, space, embed) do
          {:cont, :ok}
        else
          {:error, reason} -> {:halt, {:error, reason}}
        end
      end)

    case result do
      :ok when length(embeds) == @batch_size -> {:snooze, 1}
      other -> other
    end
  end

  defp save_progress(job, space, embed) do
    Repo.transaction(fn ->
      {:ok, _} = Spaces.enqueue_webhook_event_for_embed(space, embed, :video_deleted)

      job
      |> Ecto.Changeset.change(args: Map.put(job.args, "cursor", embed.id))
      |> Repo.update!()
    end)
  end
end
