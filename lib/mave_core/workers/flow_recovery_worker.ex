defmodule MaveCore.Workers.FlowRecoveryWorker do
  @moduledoc """
  Recovers flow work stranded after worker interruption or a lost queue handoff.
  """
  use Oban.Worker,
    queue: :flow_coordinator,
    max_attempts: 1,
    unique: [
      period: 55,
      fields: [:worker],
      states: Oban.Job.states() -- [:completed, :cancelled, :discarded]
    ]

  @impl true
  def perform(_job) do
    if enabled?() do
      {:ok, _result} = MaveCore.Flow.recover_stale_executing_steps()
      {:ok, _result} = MaveCore.Flow.recover_stale_nonexecuting_runs()
      :ok
    else
      :ok
    end
  end

  defp enabled? do
    :mave_core
    |> Application.get_env(:flow_stale_step_recovery, [])
    |> Keyword.get(:enabled, true)
  end
end
