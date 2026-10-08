defmodule MaveCore.Spaces.WebhookDelivery do
  @moduledoc false
  use MaveCore.Schema
  import Ecto.Changeset

  alias MaveCore.Spaces.{Space, Webhook}

  @states [:pending, :processing, :succeeded, :failed, :canceled]
  @response_body_limit 16 * 1024
  @response_headers_limit 20 * 1024

  schema "space_webhook_deliveries" do
    field :event_type, Ecto.Enum, values: Webhook.mave_events()
    field :payload, :map, default: %{}
    field :state, Ecto.Enum, values: @states, default: :pending
    field :attempts, :integer, default: 0
    field :next_attempt_at, :utc_datetime_usec
    field :delivered_at, :utc_datetime_usec
    field :failed_at, :utc_datetime_usec
    field :response_code, :integer
    field :response_headers, :map
    field :response_body, :string
    field :error, :string

    belongs_to :space, Space
    belongs_to :webhook, Webhook

    timestamps()
  end

  def create_changeset(delivery, attrs) do
    delivery
    |> cast(attrs, [
      :space_id,
      :webhook_id,
      :event_type,
      :payload,
      :state,
      :attempts,
      :next_attempt_at
    ])
    |> validate_required([:space_id, :webhook_id, :event_type, :payload, :state, :attempts])
  end

  def update_changeset(delivery, attrs) do
    delivery
    |> cast(attrs, [
      :state,
      :attempts,
      :next_attempt_at,
      :delivered_at,
      :failed_at,
      :response_code,
      :response_headers,
      :response_body,
      :error
    ])
    |> validate_length(:response_body, count: :bytes, max: @response_body_limit)
    |> validate_change(:response_headers, &validate_response_headers/2)
  end

  defp validate_response_headers(field, headers) when is_map(headers) do
    case Jason.encode(headers) do
      {:ok, encoded} when byte_size(encoded) <= @response_headers_limit -> []
      _ -> [{field, "is too large"}]
    end
  end

  defp validate_response_headers(_field, nil), do: []
  defp validate_response_headers(field, _headers), do: [{field, "is invalid"}]
end
