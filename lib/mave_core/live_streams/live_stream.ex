defmodule MaveCore.LiveStreams.LiveStream do
  @moduledoc false
  use MaveCore.Schema
  import Ecto.Changeset

  alias MaveCore.Spaces.Space

  @type t :: %__MODULE__{}

  schema "live_streams" do
    field :hash, :string
    field :name, :string
    field :stream_key, :string, redact: true

    # idle: never broadcast. live: an encoder is connected. disconnected: the
    # encoder dropped and may resume the broadcast. ended: replay only.
    field :status, Ecto.Enum, values: [:idle, :live, :disconnected, :ended], default: :idle

    # Counts broadcasts; segments of older broadcasts are removed.
    field :broadcast, :integer, default: 0
    field :target_duration, :integer
    field :ingest, :map
    field :last_error, :string
    field :started_at, :utc_datetime_usec
    field :disconnected_at, :utc_datetime_usec
    field :ended_at, :utc_datetime_usec
    field :heartbeat_at, :utc_datetime_usec

    belongs_to :space, Space

    timestamps()
  end

  def create_changeset(live_stream, attrs) do
    live_stream
    |> cast(attrs, [:name])
    |> validate_name()
    |> unique_constraint(:hash)
    |> unique_constraint(:stream_key)
  end

  def update_changeset(live_stream, attrs) do
    live_stream
    |> cast(attrs, [:name])
    |> validate_name()
  end

  defp validate_name(changeset) do
    changeset
    |> update_change(:name, &normalize_name/1)
    |> validate_length(:name, max: 160)
  end

  defp normalize_name(name) when is_binary(name) do
    case String.trim(name) do
      "" -> nil
      trimmed -> trimmed
    end
  end

  defp normalize_name(name), do: name
end
