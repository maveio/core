defmodule MaveCore.CliAuthorizations.Authorization do
  @moduledoc false

  use MaveCore.Schema
  import Ecto.Changeset

  alias MaveCore.Spaces.Space

  @statuses [:pending, :approved, :denied, :consumed, :expired]

  schema "cli_authorizations" do
    field :device_code_hash, :binary
    field :user_code, :string
    field :status, Ecto.Enum, values: @statuses, default: :pending
    field :expires_at, :utc_datetime_usec
    field :approved_at, :utc_datetime_usec
    field :consumed_at, :utc_datetime_usec
    field :client_metadata, :map, default: %{}

    belongs_to :space, Space

    timestamps()
  end

  def create_changeset(authorization, attrs) do
    authorization
    |> cast(attrs, [:device_code_hash, :user_code, :status, :expires_at, :client_metadata])
    |> validate_required([:device_code_hash, :user_code, :status, :expires_at])
    |> validate_length(:user_code, is: 11)
    |> check_constraint(:status, name: :cli_authorizations_status_check)
    |> unique_constraint(:device_code_hash)
    |> unique_constraint(:user_code)
  end

  def approve_changeset(authorization, space, now) do
    authorization
    |> change(status: :approved, approved_at: now, space_id: space.id)
    |> check_constraint(:status, name: :cli_authorizations_status_check)
  end

  def status_changeset(authorization, status, attrs \\ %{}) when status in @statuses do
    authorization
    |> change(Map.put(attrs, :status, status))
    |> check_constraint(:status, name: :cli_authorizations_status_check)
  end
end
