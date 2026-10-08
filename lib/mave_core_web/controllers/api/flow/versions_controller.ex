defmodule MaveCoreWeb.Api.Flow.VersionsController do
  use MaveCoreWeb, :controller

  def create(conn, %{"template_id" => template_id} = params) do
    attrs = Map.drop(params, ["template_id"])

    case MaveCore.Flow.create_version(template_id, attrs) do
      {:ok, version} ->
        conn
        |> put_status(:created)
        |> json(%{
          data: %{
            id: version.id,
            flow_template_id: version.flow_template_id,
            version: version.version,
            status: version.status,
            checksum: version.checksum,
            definition: version.definition
          }
        })

      {:error, :template_not_found} ->
        conn
        |> put_status(:not_found)
        |> json(%{error: "Template not found"})

      {:error, %Ecto.Changeset{} = changeset} ->
        conn
        |> put_status(:unprocessable_entity)
        |> put_view(json: MaveCoreWeb.ErrorJSON)
        |> render(:"422", changeset: changeset)
    end
  end
end
