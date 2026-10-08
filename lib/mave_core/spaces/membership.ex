defmodule MaveCore.Spaces.Membership do
  @moduledoc false
  use MaveCore.Schema
  import Ecto.Changeset

  alias MaveCore.Accounts.User
  alias MaveCore.Spaces.{MembershipInvite, Space}

  schema "space_memberships" do
    field :role, :string, default: "owner"

    belongs_to :user, User
    belongs_to :space, Space
    belongs_to :owner_space, Space
    belongs_to :invite, MembershipInvite

    timestamps()
  end

  def create_changeset(membership, attrs) do
    membership
    |> cast(attrs, [:user_id, :space_id, :role, :invite_id, :owner_space_id])
    |> validate_required([:space_id, :role])
    |> validate_member_source()
    |> foreign_key_constraint(:user_id)
    |> foreign_key_constraint(:space_id)
    |> foreign_key_constraint(:owner_space_id)
    |> foreign_key_constraint(:invite_id)
    |> unique_constraint([:user_id, :space_id])
    |> unique_constraint(:owner_space_id,
      name: :space_memberships_unique_owner_space_id_index
    )
    |> unique_constraint(:invite_id, name: :space_memberships_unique_invite_id_index)
  end

  defp validate_member_source(changeset) do
    if get_field(changeset, :user_id) || get_field(changeset, :invite_id) ||
         get_field(changeset, :owner_space_id) do
      changeset
    else
      add_error(changeset, :user_id, "can't be blank")
    end
  end
end
