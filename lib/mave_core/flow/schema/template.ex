defmodule MaveCore.Flow.Template do
  @moduledoc """
  A named flow template that can have multiple versions.
  """
  use MaveCore.Schema
  import Ecto.Changeset

  schema "flow_templates" do
    field :slug, :string
    field :name, :string
    field :description, :string

    has_many :flow_versions, MaveCore.Flow.Version, foreign_key: :flow_template_id
    has_many :flow_runs, MaveCore.Flow.Run, foreign_key: :flow_template_id

    timestamps()
  end

  def changeset(template, attrs) do
    template
    |> cast(attrs, [:slug, :name, :description])
    |> validate_required([:slug, :name])
    |> validate_length(:slug, min: 3, max: 100)
    |> validate_format(:slug, ~r/^[a-z0-9][a-z0-9_\-\.]*$/,
      message: "must be lower-case slug format"
    )
    |> validate_length(:name, min: 2, max: 200)
    |> unique_constraint(:slug)
  end
end
