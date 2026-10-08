defmodule MaveCore.Workers.FlowCoordinatorWorker do
  @moduledoc """
  Reconciles flow run state and schedules ready steps.
  """
  use Oban.Worker,
    queue: :flow_coordinator,
    max_attempts: 20,
    unique: [
      period: 30,
      fields: [:worker, :args],
      keys: [:flow_run_id],
      states: Oban.Job.states() -- [:completed, :cancelled, :discarded, :executing]
    ]

  @impl true
  def perform(%Oban.Job{args: %{"flow_run_id" => flow_run_id}}) when is_binary(flow_run_id) do
    case MaveCore.Flow.reconcile_run(flow_run_id) do
      {:ok, _run} -> :ok
      {:error, :not_found} -> :ok
      {:error, reason} -> {:error, inspect(reason)}
    end
  end

  def perform(_job), do: {:error, "missing flow_run_id"}
end
