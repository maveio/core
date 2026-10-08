defmodule MaveCoreWeb.UploadChannel do
  @moduledoc false
  use MaveCoreWeb, :channel

  alias MaveCore.Uploads.Events

  @impl true
  def join("embed:" <> _token, _params, %{assigns: %{error: error}} = socket)
      when not is_nil(error) do
    send(self(), {:error, error})
    {:ok, socket}
  end

  def join("embed:" <> _token, _params, socket) do
    upload_id = Ecto.UUID.generate()

    send(self(), {:after_join, upload_id})

    {:ok, assign(socket, :upload_id, upload_id)}
  end

  @impl true
  def terminate(_reason, socket) do
    if upload_id = socket.assigns[:upload_id] do
      Events.unsubscribe(upload_id)
    end

    :ok
  end

  @impl true
  def handle_info({:after_join, upload_id}, %{assigns: %{upload_id: upload_id}} = socket) do
    Events.subscribe(upload_id)
    push(socket, "initiate", %{upload_id: upload_id})
    {:noreply, socket}
  end

  def handle_info({:after_join, _stale_upload_id}, socket), do: {:noreply, socket}

  def handle_info({:error, error}, socket) do
    push(socket, "error", error)
    {:noreply, socket}
  end

  def handle_info({:completed, data}, socket) do
    push(socket, "completed", data)
    {:noreply, socket}
  end

  def handle_info({:rendition, data}, socket) do
    push(socket, "rendition", data)
    {:noreply, socket}
  end

  @impl true
  def handle_in("reset", _params, socket) do
    if upload_id = socket.assigns[:upload_id] do
      Events.unsubscribe(upload_id)
    end

    upload_id = Ecto.UUID.generate()
    Events.subscribe(upload_id)

    push(socket, "initiate", %{upload_id: upload_id})

    {:noreply, assign(socket, :upload_id, upload_id)}
  end
end
