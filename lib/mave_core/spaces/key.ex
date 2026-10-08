defmodule MaveCore.Spaces.Key do
  @moduledoc false
  use MaveCore.Schema
  import Ecto.Changeset

  alias MaveCore.Spaces.Space

  schema "space_keys" do
    field :key, :string
    field :secret, :string
    field :description, :string
    field :last_used_at, :utc_datetime_usec
    field :access_level, Ecto.Enum, values: [:read_write, :read_only], default: :read_write
    field :purpose, Ecto.Enum, values: [:dashboard_uploads]
    field :cli_metadata, :map

    belongs_to :space, Space

    timestamps()
  end

  def cli_connection?(%__MODULE__{cli_metadata: metadata}), do: is_map(metadata)

  def changeset(key, attrs) do
    key
    |> cast(attrs, [:space_id, :key, :secret, :description, :access_level, :purpose])
    |> validate_required([:space_id, :key, :secret, :access_level])
    |> validate_length(:key, min: 8, max: 80)
    |> validate_length(:secret, min: 8, max: 80)
    |> validate_length(:description, max: 160)
    |> check_constraint(:access_level, name: :space_keys_access_level_check)
    |> check_constraint(:purpose, name: :space_keys_purpose_check)
    |> unique_constraint(:key, name: :space_keys_key_index)
    |> unique_constraint(:purpose, name: :space_keys_space_id_purpose_index)
  end

  def update_changeset(key, attrs) do
    key
    |> cast(attrs, [:last_used_at, :description])
    |> validate_length(:description, max: 160)
  end

  def settings_changeset(key, attrs) do
    key
    |> cast(attrs, [:description, :access_level])
    |> validate_required([:access_level])
    |> validate_length(:description, max: 160)
    |> check_constraint(:access_level, name: :space_keys_access_level_check)
  end
end
