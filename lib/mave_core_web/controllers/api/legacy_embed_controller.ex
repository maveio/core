defmodule MaveCoreWeb.Api.LegacyEmbedController do
  use MaveCoreWeb, :controller

  alias MaveCore.EmbedId
  alias MaveCore.Embeds
  alias MaveCore.Embeds.{Embed, ManifestPublisher}
  alias MaveCore.PublicApi
  alias MaveCore.Spaces
  alias MaveCore.Spaces.Key
  alias MaveCore.Spaces.Space

  @invalid_jwt_error "Invalid JWT or collection id (either invalid sub or API key)"
  @missing_video_error "This video embed does not exist."

  def embed(conn, %{"embed_id" => embed_id}) do
    with {:ok, %{space_hash: space_hash, embed_hash: embed_hash}} <-
           EmbedId.split(String.trim(embed_id || "")),
         %Embed{type: :video} = embed <- Embeds.get_embed_by_hashes(space_hash, embed_hash),
         {:ok, manifest} <- ManifestPublisher.current(embed) do
      json(conn, manifest)
    else
      {:error, _reason} ->
        conn
        |> put_status(:internal_server_error)
        |> json(%{error: "Could not load embed manifest."})

      _not_found ->
        conn |> put_status(:not_found) |> json(%{error: @missing_video_error})
    end
  end

  def collection(conn, %{"token" => token} = params) do
    with {:ok, %{claims: claims, space: %Space{} = space}} <- Spaces.validate_api_jwt(token, true),
         root <- jwt_collection_root(claims),
         {:ok, response} <- PublicApi.jwt_collection_response(space, root, params["embed"]) do
      json(conn, response)
    else
      {:error, "Invalid JWT (sub is required)"} ->
        conn |> put_status(:bad_request) |> json(%{error: @invalid_jwt_error})

      {:error, error} when is_binary(error) ->
        conn |> put_status(:bad_request) |> json(%{error: error})

      _error ->
        conn |> put_status(:bad_request) |> json(%{error: @invalid_jwt_error})
    end
  end

  def delete_video(conn, %{"embed_hash" => embed_hash, "token" => token}) do
    case Spaces.validate_api_jwt(token, true) do
      {:ok,
       %{
         claims: %{"can_delete" => true} = claims,
         key: %Key{access_level: :read_write},
         space: %Space{} = space
       }} ->
        delete_scoped_video(conn, space, jwt_collection_root(claims), embed_hash)

      _error ->
        conn |> put_status(:bad_request) |> json(%{error: @invalid_jwt_error})
    end
  end

  defp delete_scoped_video(conn, %Space{} = space, root, embed_hash) do
    case PublicApi.get_embed(space, embed_hash) do
      nil ->
        conn |> put_status(:not_found) |> json(%{error: @missing_video_error})

      %Embed{type: :video} = embed ->
        if PublicApi.jwt_scoped_video_deletable?(space, embed, root) do
          response = PublicApi.video_response(space, embed)
          {:ok, _embed} = Embeds.delete_embed(embed)
          json(conn, response)
        else
          conn |> put_status(:bad_request) |> json(%{error: "Could not delete video"})
        end

      _embed ->
        conn |> put_status(:bad_request) |> json(%{error: "Could not delete video"})
    end
  end

  defp jwt_collection_root(%{"collection" => collection})
       when is_binary(collection) and collection != "",
       do: collection

  defp jwt_collection_root(%{"sub" => sub}), do: sub
end
