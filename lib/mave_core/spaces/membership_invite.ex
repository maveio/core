defmodule MaveCore.Spaces.MembershipInvite do
  @moduledoc false
  use MaveCore.Schema
  import Ecto.Changeset

  alias MaveCore.Accounts.User

  schema "space_membership_invites" do
    field :email, :string
    field :accepted_at, :utc_datetime_usec

    belongs_to :user, User
    belongs_to :created_by, User

    timestamps()
  end

  def create_changeset(invite, attrs) do
    invite
    |> cast(attrs, [:user_id, :email, :created_by_id, :accepted_at])
    |> update_change(:email, &normalize_email/1)
    |> validate_required([:created_by_id])
    |> validate_user_or_email()
    |> foreign_key_constraint(:user_id)
    |> foreign_key_constraint(:created_by_id)
  end

  def accept_changeset(invite) do
    change(invite, accepted_at: DateTime.utc_now())
  end

  defp validate_user_or_email(changeset) do
    if get_field(changeset, :user_id) || present?(get_field(changeset, :email)) do
      changeset
    else
      add_error(changeset, :email, "can't be blank")
    end
  end

  defp normalize_email(email) when is_binary(email) do
    email
    |> String.trim()
    |> String.downcase()
  end

  defp normalize_email(email), do: email

  defp present?(value) when is_binary(value), do: value != ""
  defp present?(_value), do: false
end
