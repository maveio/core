defmodule MaveCore.Spaces.Space do
  @moduledoc false
  use MaveCore.Schema
  import Ecto.Changeset

  alias MaveCore.SharedStorageSpace
  alias MaveCore.Spaces.{Domain, Key, Membership, Webhook}

  schema "spaces" do
    field :hash, :string
    field :region, :string
    field :public_sharing_enabled, :boolean
    field :hotlink_protection_enabled, :boolean
    field :default_flow_template, :string
    field :deleted_at, :utc_datetime_usec

    has_many :memberships, Membership
    has_many :domains, Domain
    has_many :keys, Key
    has_many :webhooks, Webhook
    timestamps()
  end

  def create_changeset(space, attrs) do
    space
    |> cast(attrs, [
      :hash,
      :region,
      :public_sharing_enabled,
      :hotlink_protection_enabled,
      :default_flow_template
    ])
    |> validate_required([:hash, :region])
    |> unique_constraint(:hash, name: :spaces_hash_index)
  end

  def features_changeset(space, attrs) do
    space
    |> cast(attrs, [:hotlink_protection_enabled])
    |> validate_shared_storage_features()
  end

  # Compatibility shims for private hosts that previously called these helpers.
  def shared_trial?(space), do: SharedStorageSpace.shared?(space)

  def shared_trial_hash, do: SharedStorageSpace.hash()

  def shared_trial_hash?(hash), do: SharedStorageSpace.hash?(hash)

  def processing_changeset(space, attrs) do
    space
    |> cast(attrs, [:default_flow_template])
    |> update_change(:default_flow_template, &normalize_flow_template/1)
    |> validate_change(:default_flow_template, fn :default_flow_template, value ->
      cond do
        is_nil(value) ->
          []

        String.match?(value, ~r/^[a-z0-9][a-z0-9_\-\.]*$/) ->
          []

        true ->
          [default_flow_template: "must be lower-case slug format"]
      end
    end)
  end

  defp normalize_flow_template(value) when is_binary(value) do
    value
    |> String.trim()
    |> case do
      "" -> nil
      trimmed -> trimmed
    end
  end

  defp normalize_flow_template(value), do: value

  defp validate_shared_storage_features(changeset) do
    if SharedStorageSpace.hash?(get_field(changeset, :hash)) and
         get_field(changeset, :hotlink_protection_enabled) == true and
         get_change(changeset, :hotlink_protection_enabled) != false do
      add_error(
        changeset,
        :hotlink_protection_enabled,
        "cannot be enabled for shared-storage spaces"
      )
    else
      changeset
    end
  end
end
