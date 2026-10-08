defmodule MaveCore.Flow.ArtifactRef do
  @moduledoc """
  Reference to a produced artifact from a step.
  """
  use MaveCore.Schema
  import Ecto.Changeset

  schema "artifact_refs" do
    field :producer_step_id, :string
    field :name, :string
    field :uri, :string
    field :media_type, :string
    field :size_bytes, :integer
    field :metadata, :map, default: %{}

    belongs_to :flow_run, MaveCore.Flow.Run

    timestamps()
  end

  def changeset(artifact, attrs) do
    artifact
    |> cast(attrs, [
      :flow_run_id,
      :producer_step_id,
      :name,
      :uri,
      :media_type,
      :size_bytes,
      :metadata
    ])
    |> validate_required([:flow_run_id, :producer_step_id, :name, :uri, :metadata])
    |> unique_constraint([:flow_run_id, :producer_step_id, :name],
      name: :artifact_refs_flow_run_id_producer_step_id_name_index
    )
  end
end
