defmodule MaveCoreWeb.Api.Data.VideosController do
  use MaveCoreWeb, :controller

  alias MaveCore.Analytics.Video, as: VideoAnalytics
  alias MaveCore.Embeds
  alias MaveCore.PublicApi
  alias MaveCore.Spaces.Space

  # GET /api/v1/videos/:embed_id/data
  def show(%{assigns: %{current_space: %Space{} = space}} = conn, %{"embed_id" => embed_id}) do
    case PublicApi.get_embed(space, String.trim(embed_id || "")) do
      %Embeds.Embed{type: :video} = embed ->
        show_video_data(conn, space.hash, embed.hash)

      nil ->
        conn |> put_status(:not_found) |> json(%{error: "This video embed does not exist."})

      _ ->
        conn
        |> put_status(:forbidden)
        |> json(%{error: "This video embed does not seem to be part of your space."})
    end
  end

  defp show_video_data(conn, space_hash, embed_hash) do
    case VideoAnalytics.data(space_hash, embed_hash) do
      {:ok, data} ->
        json(conn, %{data: data})

      _ ->
        send_resp(conn, :bad_request, "Invalid embed_id")
    end
  end
end
