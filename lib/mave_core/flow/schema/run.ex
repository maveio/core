defmodule MaveCore.Flow.Run do
  @moduledoc """
  Execution instance for a specific flow version.
  """
  use MaveCore.Schema
  import Ecto.Changeset

  @valid_statuses ~w(queued running succeeded failed cancelled)

  schema "flow_runs" do
    field :status, :string, default: "queued"
    field :input, :map, default: %{}
    field :context, :map, default: %{}
    field :error, :string
    field :started_at, :utc_datetime_usec
    field :completed_at, :utc_datetime_usec

    belongs_to :flow_template, MaveCore.Flow.Template
    belongs_to :flow_version, MaveCore.Flow.Version
    has_many :step_runs, MaveCore.Flow.StepRun, foreign_key: :flow_run_id
    has_many :artifact_refs, MaveCore.Flow.ArtifactRef, foreign_key: :flow_run_id

    timestamps()
  end

  def changeset(run, attrs) do
    run
    |> cast(attrs, [
      :flow_template_id,
      :flow_version_id,
      :status,
      :input,
      :context,
      :error,
      :started_at,
      :completed_at
    ])
    |> validate_required([:flow_template_id, :flow_version_id, :status, :input, :context])
    |> validate_inclusion(:status, @valid_statuses)
  end
end
