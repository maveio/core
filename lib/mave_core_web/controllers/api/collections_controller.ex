defmodule MaveCoreWeb.Api.CollectionsController do
  use MaveCoreWeb, :controller

  plug MaveCoreWeb.Plugs.ApiKeyWriteAuth when action in [:create, :update, :delete]

  alias MaveCore.Embeds
  alias MaveCore.PublicApi
  alias MaveCore.Spaces.Space

  def index(%{assigns: %{current_space: %Space{} = space}} = conn, params) do
    case PublicApi.resolve_collection_id(space, params["collection"]) do
      {:ok, collection_id} ->
        page = parse_int(params["page"], 1)
        per_page = parse_int(params["per_page"], nil)

        opts = [
          page: page,
          per_page: per_page,
          archived: parse_bool(params["archived"]),
          collection_id: collection_id
        ]

        data =
          PublicApi.list_collections(space, opts)
          |> Enum.map(&PublicApi.collection_response(space, &1))

        json(
          conn,
          PublicApi.list_response(data, page, per_page, PublicApi.count_collections(space, opts))
        )

      {:error, _error} ->
        conn
        |> put_status(:bad_request)
        |> json(%{error: "This collection does not seem to be part of your space."})
    end
  end

  def create(%{assigns: %{current_space: %Space{} = space}} = conn, params) do
    with {:ok, name} <- get_name(params),
         {:ok, parent_folder} <- PublicApi.resolve_collection_embed(space, params["collection"]),
         {:ok, embed} <-
           Embeds.create_folder_embed(space, %{
             name: name,
             parent_folder_id: parent_folder && parent_folder.id
           }) do
      embed = PublicApi.get_embed(space, embed.hash) || embed
      json(conn, PublicApi.collection_response(space, embed))
    else
      {:error, error} ->
        conn |> put_status(:bad_request) |> json(%{error: error})
    end
  end

  def update(%{assigns: %{current_space: %Space{} = space}} = conn, %{"hash" => hash} = params) do
    case PublicApi.get_embed(space, hash) do
      %Embeds.Embed{type: :collection} = embed ->
        with {:ok, embed} <- maybe_rename(embed, params),
             {:ok, embed} <- maybe_move(space, embed, params) do
          embed = PublicApi.get_embed(space, hash) || embed
          json(conn, PublicApi.collection_response(space, embed))
        else
          {:error, _error} ->
            conn |> put_status(:bad_request) |> json(%{error: "Can't update this collection."})
        end

      _ ->
        conn |> put_status(:bad_request) |> json(%{error: "Can't update this collection."})
    end
  end

  def delete(%{assigns: %{current_space: %Space{} = space}} = conn, %{"hash" => hash}) do
    case PublicApi.get_embed(space, hash) do
      %Embeds.Embed{type: :collection} = embed ->
        response = PublicApi.collection_response(space, embed)
        {:ok, _embed} = Embeds.delete_embed(embed)
        json(conn, response)

      nil ->
        conn |> put_status(:not_found) |> json(%{error: "This video embed does not exist."})

      _ ->
        conn
        |> put_status(:forbidden)
        |> json(%{error: "This collection does not seem to be part of your space."})
    end
  end

  defp get_name(%{"name" => name}) when is_binary(name) and name != "", do: {:ok, name}
  defp get_name(_params), do: {:error, "Add a name to create a collection"}

  defp maybe_rename(%Embeds.Embed{} = embed, %{"name" => name}),
    do: Embeds.rename_embed(embed, name)

  defp maybe_rename(%Embeds.Embed{} = embed, _params), do: {:ok, embed}

  defp maybe_move(%Space{} = space, %Embeds.Embed{} = embed, %{"collection" => collection_hash}) do
    with {:ok, target} <- PublicApi.resolve_collection_embed(space, collection_hash) do
      Embeds.move_embed(embed, target)
    end
  end

  defp maybe_move(_space, %Embeds.Embed{} = embed, _params), do: {:ok, embed}

  defp parse_int(nil, default), do: default

  defp parse_int(value, default) when is_binary(value) do
    case Integer.parse(value) do
      {parsed, _rest} when parsed > 0 -> parsed
      :error -> default
      _ -> default
    end
  end

  defp parse_bool("true"), do: true
  defp parse_bool("false"), do: false
  defp parse_bool(_), do: false
end
