defmodule MaveCore.Flow.Version do
  @moduledoc """
  Immutable flow definition version for a template.
  """
  use MaveCore.Schema
  import Ecto.Changeset

  alias MaveCore.Flow.Definition

  @valid_statuses ~w(active archived)

  schema "flow_versions" do
    field :version, :integer
    field :status, :string, default: "active"
    field :definition, :map
    field :checksum, :string

    belongs_to :flow_template, MaveCore.Flow.Template
    has_many :flow_runs, MaveCore.Flow.Run, foreign_key: :flow_version_id

    timestamps()
  end

  def changeset(version, attrs) do
    version
    |> cast(attrs, [:flow_template_id, :version, :status, :definition, :checksum])
    |> validate_required([:flow_template_id, :version, :status, :definition, :checksum])
    |> validate_number(:version, greater_than_or_equal_to: 1)
    |> validate_inclusion(:status, @valid_statuses)
    |> validate_definition()
    |> unique_constraint([:flow_template_id, :version])
  end

  defp validate_definition(changeset) do
    definition = get_field(changeset, :definition)

    case Definition.validate(definition) do
      :ok ->
        changeset

      {:error, message} ->
        add_error(changeset, :definition, message)
    end
  end
end
