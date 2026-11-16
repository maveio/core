defmodule MaveCoreWeb.Api.LiveStreamsController do
  use MaveCoreWeb, :controller

  plug MaveCoreWeb.Plugs.ApiKeyWriteAuth when action in [:create, :update, :delete, :reset_key]
  plug :require_live_streaming

  alias MaveCore.LiveStreams
  alias MaveCore.LiveStreams.LiveStream
  alias MaveCore.Spaces.Space

  def index(%{assigns: %{current_space: %Space{} = space}} = conn, _params) do
    data = space |> LiveStreams.list() |> Enum.map(&LiveStreams.response(space, &1))
    json(conn, %{object: "list", data: data})
  end

  def show(conn, %{"id" => id}) do
    with_stream(conn, id, &json(conn, LiveStreams.response(conn.assigns.current_space, &1)))
  end

  def create(%{assigns: %{current_space: %Space{} = space}} = conn, params) do
    case LiveStreams.create(space, Map.take(params, ["name"])) do
      {:ok, stream} ->
        conn |> put_status(:created) |> json(LiveStreams.response(space, stream))

      {:error, changeset} ->
        invalid(conn, changeset)
    end
  end

  def update(conn, %{"id" => id} = params) do
    with_stream(conn, id, fn stream ->
      case LiveStreams.update(stream, Map.take(params, ["name"])) do
        {:ok, stream} -> json(conn, LiveStreams.response(conn.assigns.current_space, stream))
        {:error, changeset} -> invalid(conn, changeset)
      end
    end)
  end

  def reset_key(conn, %{"id" => id}) do
    with_stream(conn, id, fn stream ->
      {:ok, stream} = LiveStreams.reset_stream_key(stream)
      json(conn, LiveStreams.response(conn.assigns.current_space, stream))
    end)
  end

  def delete(conn, %{"id" => id}) do
    with_stream(conn, id, fn stream ->
      {:ok, _stream} = LiveStreams.delete(stream)
      send_resp(conn, :no_content, "")
    end)
  end

  defp with_stream(%{assigns: %{current_space: %Space{} = space}} = conn, id, fun) do
    case LiveStreams.get(space, id) do
      %LiveStream{} = stream ->
        fun.(stream)

      nil ->
        conn |> put_status(:not_found) |> json(%{error: "This live stream does not exist."})
    end
  end

  defp invalid(conn, %Ecto.Changeset{}),
    do: conn |> put_status(:unprocessable_entity) |> json(%{error: "The name is too long."})

  defp invalid(conn, _reason), do: unavailable(conn)

  defp require_live_streaming(%{assigns: %{current_space: %Space{} = space}} = conn, _opts) do
    if LiveStreams.available?(space), do: conn, else: conn |> unavailable() |> halt()
  end

  defp unavailable(conn) do
    conn
    |> put_status(:forbidden)
    |> json(%{error: "Live streaming is not available for this space."})
  end
end
