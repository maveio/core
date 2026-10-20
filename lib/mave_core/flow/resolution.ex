defmodule MaveCore.Flow.Resolution do
  @moduledoc """
  Separates open failures from historical failures that no longer need action.

  Execution status, step errors and artifacts remain unchanged. A later
  successful run for the same embed resolves earlier failures automatically;
  operators may explicitly close a failed run whose source cannot be used.
  """
  import Ecto.Query

  alias MaveCore.Flow.{Events, Run, StepRun}
  alias MaveCore.Repo

  def query do
    successes =
      from run in Run,
        where: run.status == "succeeded",
        group_by: fragment("?->>'embed_hash'", run.input),
        select: %{
          embed_hash: fragment("?->>'embed_hash'", run.input),
          inserted_at: max(run.inserted_at)
        }

    from run in Run,
      left_join: success in subquery(successes),
      on:
        fragment("?->>'embed_hash'", run.input) == success.embed_hash and
          run.inserted_at < success.inserted_at,
      where:
        run.status == "failed" and
          (not is_nil(success.embed_hash) or
             fragment("?->'resolution'->>'kind' = 'source_unusable'", run.context)),
      select: %{id: run.id, later_succeeded: not is_nil(success.embed_hash)}
  end

  def run_ids_query, do: from(resolution in subquery(query()), select: resolution.id)

  def for_runs([]), do: %{}

  def for_runs(runs) do
    ids = Enum.map(runs, & &1.id)

    query()
    |> where([run], run.id in ^ids)
    |> Repo.all()
    |> Map.new(fn row ->
      {row.id, if(row.later_succeeded, do: :later_succeeded, else: :source_unusable)}
    end)
  end

  def close_unusable_source(run_id) when is_binary(run_id) do
    Repo.transaction(fn ->
      run = Repo.one(from run in Run, where: run.id == ^run_id, lock: "FOR UPDATE")

      ensure_closable!(run)

      resolution = %{
        "kind" => "source_unusable",
        "closed_at" => DateTime.utc_now() |> DateTime.to_iso8601()
      }

      run
      |> Run.changeset(%{context: Map.put(run.context || %{}, "resolution", resolution)})
      |> Repo.update!()
    end)
    |> case do
      {:ok, run} ->
        Events.broadcast_updated(run.id, %{
          "status" => run.status,
          "resolution" => "source_unusable"
        })

        {:ok, run}

      error ->
        error
    end
  end

  defp ensure_closable!(nil), do: Repo.rollback(:not_found)

  defp ensure_closable!(%Run{status: status}) when status != "failed",
    do: Repo.rollback(:not_failed)

  defp ensure_closable!(%Run{id: run_id}) do
    cond do
      Repo.exists?(from r in subquery(run_ids_query()), where: r.id == ^run_id) ->
        Repo.rollback(:already_resolved)

      Repo.exists?(
        from step in StepRun, where: step.flow_run_id == ^run_id and step.status == "executing"
      ) ->
        Repo.rollback(:step_running)

      true ->
        :ok
    end
  end
end
