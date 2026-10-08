defmodule MaveCoreWeb.Api.Data.SpacesController do
  use MaveCoreWeb, :controller

  alias MaveCore.Analytics
  alias MaveCore.UsageLimits

  # GET /api/v1/spaces/:space_hash/data
  def show(%{assigns: %{current_space: current_space}} = conn, %{"space_hash" => space_hash}) do
    case String.trim(space_hash || "") do
      hash when hash == current_space.hash ->
        case UsageLimits.can_view_space_data?(current_space) do
          :ok ->
            show_space_data(conn, current_space.hash)

          {:error, reason} ->
            conn |> put_status(:forbidden) |> json(%{error: format_error(reason)})
        end

      _ ->
        send_resp(conn, :not_found, "Not found")
    end
  end

  defp show_space_data(conn, space_hash) do
    case Analytics.space_data(space_hash) do
      {:ok, data} ->
        json(conn, %{data: data})

      _ ->
        send_resp(conn, :bad_request, "Invalid space_hash")
    end
  end

  defp format_error(_reason), do: "This space cannot view aggregate data."
end
