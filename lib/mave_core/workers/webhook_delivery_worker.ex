defmodule MaveCore.Workers.WebhookDeliveryWorker do
  @moduledoc """
  Delivers queued space webhook deliveries with retry scheduling.
  """
  use Oban.Worker,
    queue: :webhooks,
    max_attempts: 20,
    unique: [period: 60, fields: [:worker, :args], keys: [:delivery_id]]

  alias MaveCore.Spaces

  @impl true
  def perform(%Oban.Job{args: %{"delivery_id" => delivery_id}})
      when is_binary(delivery_id) do
    case Spaces.process_webhook_delivery(delivery_id) do
      {:ok, _result} -> :ok
      {:retry, seconds} when is_integer(seconds) and seconds > 0 -> {:snooze, seconds}
      {:error, reason} -> {:error, inspect(reason)}
    end
  end

  def perform(_job), do: {:error, "missing delivery_id"}
end
