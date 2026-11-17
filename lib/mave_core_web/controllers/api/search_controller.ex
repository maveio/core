defmodule MaveCoreWeb.Api.SearchController do
  @moduledoc """
  Content search over a space's videos: by what is on screen and what is said.

  `index` serves API keys (the whole space, or `collection`). `collection`
  serves the signed collection tokens browser components already use; the
  token decides the scope. See `docs/video_search.md`.
  """
  use MaveCoreWeb, :controller

  alias MaveCore.PublicApi
  alias MaveCore.Spaces
  alias MaveCore.Spaces.Space

  @invalid_jwt_error "Invalid JWT or collection id (either invalid sub or API key)"
  @max_query_length 200

  def index(%{assigns: %{current_space: %Space{} = space}} = conn, params) do
    with {:ok, query} <- search_query(params),
         {:ok, response} <-
           PublicApi.search(space, query, [collection: params["collection"]] ++ options(params)) do
      json(conn, response)
    else
      {:error, error} -> conn |> put_status(:bad_request) |> json(%{error: error})
    end
  end

  def collection(conn, %{"token" => token} = params) do
    with {:ok, query} <- search_query(params),
         {:ok, %{claims: claims, space: %Space{} = space}} <- Spaces.validate_api_jwt(token, true),
         {:ok, response} <-
           PublicApi.jwt_search(space, jwt_collection_root(claims), query, options(params)) do
      json(conn, response)
    else
      {:error, "Invalid JWT (sub is required)"} ->
        conn |> put_status(:bad_request) |> json(%{error: @invalid_jwt_error})

      {:error, error} when is_binary(error) ->
        conn |> put_status(:bad_request) |> json(%{error: error})
    end
  end

  defp search_query(%{"q" => query}) when is_binary(query) do
    if String.length(query) <= @max_query_length,
      do: {:ok, query},
      else: {:error, "The search query is too long."}
  end

  defp search_query(_params), do: {:error, "Missing search query (q)."}

  defp options(params) do
    [
      limit: positive_integer(params["limit"]),
      moments_per_video: positive_integer(params["moments"])
    ]
  end

  defp positive_integer(value) when is_binary(value) do
    case Integer.parse(value) do
      {number, ""} when number > 0 -> number
      _ -> nil
    end
  end

  defp positive_integer(_value), do: nil

  defp jwt_collection_root(%{"collection" => collection})
       when is_binary(collection) and collection != "",
       do: collection

  defp jwt_collection_root(%{"sub" => sub}), do: sub
end
