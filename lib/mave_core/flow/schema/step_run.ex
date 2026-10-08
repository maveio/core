defmodule MaveCore.Flow.StepRun do
  @moduledoc """
  Execution state for one step inside a flow run.
  """
  use MaveCore.Schema
  import Ecto.Changeset

  @valid_statuses ~w(queued scheduled executing succeeded failed cancelled skipped)

  schema "step_runs" do
    field :step_id, :string
    field :step_type, :string
    field :status, :string, default: "queued"
    field :attempt, :integer, default: 0
    field :input, :map, default: %{}
    field :output, :map
    field :execution_metadata, :map, default: %{}
    field :error, :string
    field :scheduled_at, :utc_datetime_usec
    field :started_at, :utc_datetime_usec
    field :completed_at, :utc_datetime_usec

    belongs_to :flow_run, MaveCore.Flow.Run

    timestamps()
  end

  def changeset(step_run, attrs) do
    step_run
    |> cast(attrs, [
      :flow_run_id,
      :step_id,
      :step_type,
      :status,
      :attempt,
      :input,
      :output,
      :execution_metadata,
      :error,
      :scheduled_at,
      :started_at,
      :completed_at
    ])
    |> validate_required([
      :flow_run_id,
      :step_id,
      :step_type,
      :status,
      :attempt,
      :input,
      :execution_metadata
    ])
    |> validate_inclusion(:status, @valid_statuses)
    |> validate_number(:attempt, greater_than_or_equal_to: 0)
    |> unique_constraint([:flow_run_id, :step_id], name: :step_runs_flow_run_id_step_id_index)
  end
end
