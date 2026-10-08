defmodule MaveCoreWeb.Api.Flow.TemplatesController do
  use MaveCoreWeb, :controller

  def create(conn, params) do
    case MaveCore.Flow.create_template(params) do
      {:ok, template} ->
        conn
        |> put_status(:created)
        |> json(%{
          data: %{
            id: template.id,
            slug: template.slug,
            name: template.name,
            description: template.description
          }
        })

      {:error, %Ecto.Changeset{} = changeset} ->
        conn
        |> put_status(:unprocessable_entity)
        |> put_view(json: MaveCoreWeb.ErrorJSON)
        |> render(:"422", changeset: changeset)
    end
  end
end
