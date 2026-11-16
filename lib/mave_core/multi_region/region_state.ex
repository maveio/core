defmodule MaveCore.MultiRegion.RegionState do
  @moduledoc """
  Health and replication state of one storage region of a space.

  The primary region only uses the health fields; its media is the source that
  replicas copy from.
  """
  use MaveCore.Schema
  import Ecto.Changeset

  alias MaveCore.Spaces.Space

  @health ~w(unknown healthy unavailable)
  @sync_status ~w(pending syncing synced failed)

  schema "space_region_states" do
    field :region, :string

    field :health, :string, default: "unknown"
    field :health_error, :string
    field :health_checked_at, :utc_datetime_usec
    field :health_changed_at, :utc_datetime_usec
    field :consecutive_successes, :integer, default: 0

    field :sync_status, :string, default: "pending"
    field :sync_error, :string
    field :sync_started_at, :utc_datetime_usec
    field :synced_at, :utc_datetime_usec
    field :objects_total, :integer, default: 0
    field :bytes_total, :integer, default: 0
    field :objects_pending, :integer, default: 0
    field :last_copied, :integer, default: 0
    field :last_deleted, :integer, default: 0

    belongs_to :space, Space

    timestamps()
  end

  def changeset(state, attrs) do
    state
    |> cast(attrs, [
      :health,
      :health_error,
      :health_checked_at,
      :health_changed_at,
      :consecutive_successes,
      :sync_status,
      :sync_error,
      :sync_started_at,
      :synced_at,
      :objects_total,
      :bytes_total,
      :objects_pending,
      :last_copied,
      :last_deleted
    ])
    |> validate_inclusion(:health, @health)
    |> validate_inclusion(:sync_status, @sync_status)
    |> update_change(:health_error, &truncate/1)
    |> update_change(:sync_error, &truncate/1)
    |> unique_constraint([:space_id, :region])
  end

  defp truncate(nil), do: nil
  defp truncate(value) when is_binary(value), do: String.slice(value, 0, 250)
end
