defmodule MaveCore.Accounts.User do
  @moduledoc false
  use MaveCore.Schema
  import Ecto.Changeset

  alias MaveCore.Accounts.EmailValidator
  alias MaveCore.Repo
  alias MaveCore.Spaces.Membership
  alias MaveCore.Spaces.Space

  @empty_email_message "Seems to be empty"
  @invalid_email_message "Doesn't seem right"
  @already_registered_message "Already registered?"

  schema "users" do
    field :email, :string
    field :google_uid, :string
    field :google_uid_pending_since, :utc_datetime_usec
    field :confirmed_at, :utc_datetime_usec
    field :deleted_at, :utc_datetime_usec

    has_many :space_memberships, Membership
    many_to_many :spaces, Space, join_through: Membership

    belongs_to :current_space_membership, Membership, on_replace: :nilify
    has_one :current_space, through: [:current_space_membership, :space]

    timestamps()
  end

  def login_changeset(user, attrs) do
    user
    |> cast(attrs, [:email])
    |> update_change(:email, &String.trim/1)
    |> validate_required([:email], message: @empty_email_message)
    |> validate_email_format()
  end

  def registration_changeset(user, attrs, opts \\ []) do
    skip_email_validation? = Keyword.get(opts, :skip_email_validation, false)

    user
    |> cast(attrs, [:email, :google_uid, :confirmed_at, :current_space_membership_id])
    |> update_change(:email, &String.trim/1)
    |> validate_required([:email], message: @empty_email_message)
    |> validate_email_format()
    |> maybe_validate_email_records(skip_email_validation?)
    |> unsafe_validate_unique(:email, Repo, message: @already_registered_message)
    |> unique_constraint(:email, message: @already_registered_message)
  end

  def confirm_changeset(user) do
    change(user, confirmed_at: DateTime.utc_now())
  end

  def google_uid_changeset(user, google_uid) do
    user
    |> cast(%{google_uid: google_uid, google_uid_pending_since: nil}, [
      :google_uid,
      :google_uid_pending_since
    ])
    |> validate_required([:google_uid])
  end

  def google_uid_pending_changeset(user, pending_since) do
    user
    |> cast(%{google_uid_pending_since: pending_since}, [:google_uid_pending_since])
  end

  def unlink_google_changeset(user) do
    user
    |> cast(%{google_uid: nil, google_uid_pending_since: nil}, [
      :google_uid,
      :google_uid_pending_since
    ])
  end

  def current_space_membership_changeset(user, membership_id) do
    user
    |> cast(%{current_space_membership_id: membership_id}, [:current_space_membership_id])
    |> foreign_key_constraint(:current_space_membership_id)
  end

  defp validate_email_format(changeset) do
    changeset
    |> validate_format(:email, ~r/^[^\s]+@[^\s]+$/, message: @invalid_email_message)
    |> validate_length(:email, max: 160)
  end

  defp maybe_validate_email_records(changeset, true), do: changeset

  defp maybe_validate_email_records(changeset, false) do
    if changed?(changeset, :email) do
      changeset
      |> get_change(:email)
      |> EmailValidator.check_email()
      |> case do
        {:ok, true} ->
          changeset

        {:error, _reason} ->
          add_error(changeset, :email, @invalid_email_message)
      end
    else
      changeset
    end
  end
end
