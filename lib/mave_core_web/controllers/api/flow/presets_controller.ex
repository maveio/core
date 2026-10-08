defmodule MaveCoreWeb.Api.Flow.PresetsController do
  use MaveCoreWeb, :controller

  def index(conn, _params) do
    json(conn, %{data: MaveCore.Flow.list_presets()})
  end

  def install(conn, %{"slug" => slug}) do
    case MaveCore.Flow.install_preset(slug) do
      {:ok, result} ->
        status = if result.version_created, do: :created, else: :ok

        conn
        |> put_status(status)
        |> json(%{
          data: %{
            preset: slug,
            template: %{
              id: result.template.id,
              slug: result.template.slug,
              name: result.template.name,
              description: result.template.description
            },
            version: %{
              id: result.version.id,
              number: result.version.version,
              status: result.version.status,
              checksum: result.version.checksum
            },
            version_created: result.version_created
          }
        })

      {:error, :preset_not_found} ->
        conn
        |> put_status(:not_found)
        |> json(%{error: "Preset not found"})

      {:error, %Ecto.Changeset{} = changeset} ->
        conn
        |> put_status(:unprocessable_entity)
        |> put_view(json: MaveCoreWeb.ErrorJSON)
        |> render(:"422", changeset: changeset)

      {:error, reason} ->
        conn
        |> put_status(:internal_server_error)
        |> json(%{error: "Failed to install preset", details: inspect(reason)})
    end
  end
end
