defmodule MaveCore.Spaces.Webhook do
  @moduledoc false
  use MaveCore.Schema
  import Ecto.Changeset

  alias MaveCore.Spaces.Space

  @empty_message "Seems to be empty"
  @requires_https_message "We need https to make it work"
  @invalid_message "This doesn't seem like a valid url"

  @required_fields ~w(secret url enabled_events)a
  @optional_fields ~w(description enabled space_id)a

  @mave_events [
    :video_created,
    :video_uploaded,
    :video_deleted,
    :video_archived,
    :video_unarchived,
    :video_processing,
    :video_ready
  ]

  def mave_events, do: @mave_events

  schema "space_webhooks" do
    field :description, :string
    field :enabled, :boolean, default: true
    field :url, :string
    field :secret, :string
    field :enabled_events, {:array, Ecto.Enum}, values: @mave_events

    belongs_to :space, Space

    timestamps()
  end

  def changeset(webhook, attrs) do
    webhook
    |> cast(attrs, @required_fields ++ @optional_fields)
    |> validate_required(@required_fields, message: @empty_message)
    |> update_change(:url, &String.trim/1)
    |> validate_url(:url)
  end

  def validate_url(changeset, field, opts \\ []) do
    validate_change(changeset, field, fn _, value ->
      value
      |> validate_url_value()
      |> case do
        error when is_binary(error) -> [{field, Keyword.get(opts, :message, error)}]
        _ -> []
      end
    end)
  end

  defp validate_url_value(value) do
    case URI.parse(value) do
      %URI{scheme: nil} ->
        @requires_https_message

      %URI{scheme: "http"} ->
        @requires_https_message

      %URI{scheme: "https", host: host} when is_binary(host) and host != "" ->
        nil

      _ ->
        @invalid_message
    end
  end
end
