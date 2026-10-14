defmodule MaveCoreWeb.Api.WebhooksController do
  use MaveCoreWeb, :controller

  alias MaveCore.Spaces

  plug MaveCoreWeb.Plugs.ApiKeyWriteAuth when action in [:create, :delete]

  def index(conn, _params) do
    data = Enum.map(Spaces.list_webhooks(conn.assigns.current_space), &serialize/1)
    json(conn, %{data: data})
  end

  def create(conn, params) do
    case Spaces.register_webhook(conn.assigns.current_space, params) do
      {:ok, {webhook, status}} ->
        conn
        |> put_status(if(status == :created, do: :created, else: :ok))
        |> json(%{data: serialize(webhook)})

      {:error, %Ecto.Changeset{} = changeset} ->
        errors = Ecto.Changeset.traverse_errors(changeset, fn {message, _opts} -> message end)
        conn |> put_status(:unprocessable_entity) |> json(%{errors: errors})
    end
  end

  def delete(conn, %{"id" => id}) do
    {:ok, _result} = Spaces.unregister_webhook(conn.assigns.current_space, id)
    send_resp(conn, :no_content, "")
  end

  defp serialize(webhook) do
    %{
      id: webhook.id,
      url: webhook.url,
      enabled_events: webhook.enabled_events,
      enabled: webhook.enabled,
      created_at: webhook.inserted_at
    }
  end
end
