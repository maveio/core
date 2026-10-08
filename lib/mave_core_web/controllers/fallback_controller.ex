defmodule MaveCoreWeb.FallbackController do
  use MaveCoreWeb, :controller

  def call(conn, {:error, %Ecto.Changeset{} = changeset}) do
    conn
    |> put_status(:unprocessable_entity)
    |> put_view(json: MaveCoreWeb.ErrorJSON)
    |> render(:"422", changeset: changeset)
  end

  def call(conn, {:error, :not_found}) do
    conn
    |> put_status(:not_found)
    |> put_view(json: MaveCoreWeb.ErrorJSON)
    |> render(:"404")
  end

  def call(conn, _err) do
    conn
    |> put_status(:internal_server_error)
    |> put_view(json: MaveCoreWeb.ErrorJSON)
    |> render(:"500")
  end
end
