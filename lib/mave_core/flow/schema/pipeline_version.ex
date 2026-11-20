defmodule MaveCore.Flow.PipelineVersion do
  @moduledoc """
  One saved version of a space's encoding pipeline.

  A version stores the overrides the space applies to its flow (see
  `MaveCore.Flow.Pipeline`). Versions are never changed; the newest one applies
  to new uploads.
  """
  use MaveCore.Schema
  import Ecto.Changeset

  schema "flow_pipeline_versions" do
    field :version, :integer
    field :overrides, :map, default: %{}
    field :note, :string

    belongs_to :space, MaveCore.Spaces.Space
    belongs_to :created_by, MaveCore.Accounts.User

    timestamps(updated_at: false)
  end

  def changeset(pipeline_version, attrs) do
    pipeline_version
    |> cast(attrs, [:space_id, :created_by_id, :version, :overrides, :note])
    |> validate_required([:space_id, :version, :overrides])
    |> validate_number(:version, greater_than_or_equal_to: 1)
    |> validate_length(:note, max: 200)
    |> unique_constraint([:space_id, :version])
  end
end
