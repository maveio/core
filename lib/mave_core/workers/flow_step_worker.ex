defmodule MaveCore.Workers.FlowStepWorker do
  @moduledoc """
  Executes a single step run.
  """
  use Oban.Worker,
    queue: :flow_steps,
    max_attempts: 5,
    unique: [
      period: 300,
      fields: [:worker, :args],
      keys: [:flow_run_id, :step_id],
      states: :incomplete
    ]

  @impl true
  def perform(%Oban.Job{args: %{"flow_run_id" => flow_run_id, "step_id" => step_id}} = job)
      when is_binary(flow_run_id) and is_binary(step_id) do
    flow_run_id
    |> MaveCore.Flow.execute_step(step_id, fair_queue: job.queue, oban_attempt: job.attempt)
    |> normalize_execute_step_result()
  end

  def perform(_job), do: {:error, "missing flow_run_id or step_id"}

  defp normalize_execute_step_result({:ok, _output}), do: :ok
  defp normalize_execute_step_result({:error, :already_succeeded}), do: :ok
  defp normalize_execute_step_result({:error, :step_failed}), do: :ok
  defp normalize_execute_step_result({:error, :step_skipped}), do: :ok
  defp normalize_execute_step_result({:error, :step_cancelled}), do: :ok
  defp normalize_execute_step_result({:error, :run_not_running}), do: :ok
  defp normalize_execute_step_result({:error, :already_executing}), do: :ok
  defp normalize_execute_step_result({:error, :automatic_attempts_exhausted}), do: :ok

  defp normalize_execute_step_result({:error, {:fair_queue_busy, seconds}}),
    do: {:snooze, seconds}

  defp normalize_execute_step_result({:error, {:booster_capacity_busy, seconds}}),
    do: {:snooze, seconds}

  defp normalize_execute_step_result(
         {:error, {:transient_step_retry_scheduled, _reason, seconds}}
       ),
       do: {:snooze, seconds}

  defp normalize_execute_step_result({:error, reason}), do: {:error, inspect(reason)}
end
