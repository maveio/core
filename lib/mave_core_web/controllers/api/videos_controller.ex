defmodule MaveCoreWeb.Api.VideosController do
  use MaveCoreWeb, :controller

  plug(MaveCoreWeb.Plugs.ApiKeyWriteAuth when action in [:create, :update, :delete])

  alias MaveCore.Embeds
  alias MaveCore.PublicApi
  alias MaveCore.Spaces.Space

  def index(%{assigns: %{current_space: %Space{} = space}} = conn, params) do
    case resolve_collection(params, space) do
      {:ok, collection_id} ->
        page = parse_int(params["page"], 1)
        per_page = parse_int(params["per_page"], nil)

        opts = [
          page: page,
          per_page: per_page,
          uploaded: parse_optional_bool(params["uploaded"]),
          archived: parse_bool(params["archived"]),
          collection_id: collection_id,
          show_collections: params["show_collections"] == "true"
        ]

        data =
          PublicApi.list_videos(space, opts)
          |> Enum.map(&serialize_embed(space, &1))

        response =
          data
          |> PublicApi.list_response(page, per_page, PublicApi.count_videos(space, opts))
          |> Map.put(:space_id, space.id)

        json(conn, response)

      {:error, error} ->
        conn |> put_status(:forbidden) |> json(%{error: error})
    end
  end

  def show(%{assigns: %{current_space: %Space{} = space}} = conn, %{"hash" => hash}) do
    case PublicApi.get_embed(space, hash) do
      %Embeds.Embed{type: :video} = embed ->
        conn
        |> put_visibility_response_status(embed)
        |> json(PublicApi.video_response(space, embed))

      nil ->
        conn |> put_status(:not_found) |> json(%{error: "This video embed does not exist."})

      _ ->
        conn
        |> put_status(:forbidden)
        |> json(%{error: "This video embed does not seem to be part of your space."})
    end
  end

  def owner(%{assigns: %{current_space: %Space{} = space}} = conn, %{"hash" => hash}) do
    case PublicApi.get_embed(space, hash) do
      %Embeds.Embed{type: :video} ->
        json(conn, %{space_id: space.id})

      nil ->
        conn |> put_status(:not_found) |> json(%{error: "This video embed does not exist."})

      _ ->
        conn
        |> put_status(:forbidden)
        |> json(%{error: "This video embed does not seem to be part of your space."})
    end
  end

  def create(%{assigns: %{current_space: %Space{} = space}} = conn, params) do
    with {:ok, parent_folder_id} <- resolve_parent_folder_id(space, params),
         :ok <-
           MaveCore.Playback.validate_visibility(space, Map.get(params, "visibility", "public")),
         :ok <- maybe_validate_input_url(params),
         {:ok, embed} <-
           Embeds.create_video_embed(space, %{
             name: blank_to_nil(params["name"]),
             visibility: Map.get(params, "visibility", "public"),
             parent_folder_id: parent_folder_id
           }),
         :ok <- maybe_start_input_url_upload(space, embed, params) do
      embed = PublicApi.get_embed_by_hash(space, embed.hash) || embed
      json(conn, PublicApi.video_response(space, embed))
    else
      {:error, error} when is_binary(error) ->
        conn |> put_status(:bad_request) |> json(%{error: error})

      {:error, reason} ->
        conn |> put_status(:bad_request) |> json(%{error: format_error(reason)})
    end
  end

  def update(%{assigns: %{current_space: %Space{} = space}} = conn, %{"hash" => hash} = params) do
    case PublicApi.get_embed(space, hash) do
      %Embeds.Embed{type: :video} = embed ->
        with :ok <-
               MaveCore.Playback.validate_visibility(
                 space,
                 Map.get(params, "visibility", "public")
               ),
             {:ok, embed} <- maybe_rename(embed, params),
             {:ok, embed} <- maybe_move(space, embed, params),
             {:ok, embed} <- maybe_playback_visibility(embed, params) do
          embed = PublicApi.get_embed(space, hash) || embed

          conn
          |> maybe_put_visibility_response_status(params, embed)
          |> json(PublicApi.video_response(space, embed))
        else
          {:error, error} ->
            conn |> put_status(:bad_request) |> json(%{error: format_error(error)})
        end

      nil ->
        conn |> put_status(:not_found) |> json(%{error: "This video embed does not exist."})

      _ ->
        conn
        |> put_status(:forbidden)
        |> json(%{error: "This video embed does not seem to be part of your space."})
    end
  end

  def delete(%{assigns: %{current_space: %Space{} = space}} = conn, %{"hash" => hash}) do
    case PublicApi.get_embed(space, hash) do
      %Embeds.Embed{type: :video} = embed ->
        response = PublicApi.video_response(space, embed)
        {:ok, _embed} = Embeds.delete_embed(embed)
        json(conn, response)

      nil ->
        conn |> put_status(:not_found) |> json(%{error: "This video embed does not exist."})

      _ ->
        conn
        |> put_status(:forbidden)
        |> json(%{error: "This video embed does not seem to be part of your space."})
    end
  end

  defp serialize_embed(space, %Embeds.Embed{type: :collection} = embed),
    do: PublicApi.collection_response(space, embed)

  defp serialize_embed(space, %Embeds.Embed{} = embed), do: PublicApi.video_response(space, embed)

  defp maybe_put_visibility_response_status(conn, %{"visibility" => _}, embed),
    do: put_visibility_response_status(conn, embed)

  defp maybe_put_visibility_response_status(conn, _params, _embed), do: conn

  defp put_visibility_response_status(conn, %{playback_status: status})
       when status in [:protecting, :publishing],
       do: put_status(conn, :accepted)

  defp put_visibility_response_status(conn, _embed), do: conn

  defp maybe_playback_visibility(embed, %{"visibility" => "private"}),
    do: MaveCore.Playback.request_visibility(embed, :private)

  defp maybe_playback_visibility(embed, %{"visibility" => "public"}),
    do: MaveCore.Playback.request_visibility(embed, :public)

  defp maybe_playback_visibility(_embed, %{"visibility" => _}), do: {:error, :invalid_visibility}
  defp maybe_playback_visibility(embed, _params), do: {:ok, embed}

  defp resolve_collection(params, space),
    do: PublicApi.resolve_collection_id(space, params["collection"])

  defp resolve_parent_folder_id(space, params) do
    case PublicApi.resolve_collection_embed(space, params["collection"]) do
      {:ok, nil} -> {:ok, nil}
      {:ok, embed} -> {:ok, embed.id}
      {:error, error} -> {:error, error}
    end
  end

  defp maybe_start_input_url_upload(
         %Space{} = space,
         %Embeds.Embed{} = embed,
         %{"input_url" => input_url} = params
       )
       when is_binary(input_url) and input_url != "" do
    PublicApi.start_input_url_upload(space, embed, input_url, params)
  end

  defp maybe_start_input_url_upload(_space, _embed, _params), do: :ok

  defp maybe_validate_input_url(%{"input_url" => input_url})
       when is_binary(input_url) and input_url != "" do
    PublicApi.validate_input_url(input_url)
  end

  defp maybe_validate_input_url(_params), do: :ok

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

  defp parse_optional_bool("true"), do: true
  defp parse_optional_bool("false"), do: false
  defp parse_optional_bool(_), do: nil

  defp blank_to_nil(nil), do: nil
  defp blank_to_nil(""), do: nil
  defp blank_to_nil(value), do: value

  defp format_error(:invalid_target_folder),
    do: "This collection does not seem to be part of your space."

  defp format_error(:cross_space_move),
    do: "This collection does not seem to be part of your space."

  defp format_error(:not_found), do: "This video embed does not exist."
  defp format_error(:invalid_visibility), do: "visibility must be public or private."
  defp format_error(:playback_unavailable), do: "Private playback is unavailable for this space."
  defp format_error(:embed_limit_reached), do: "This space has reached its video limit."
  defp format_error(error) when is_binary(error), do: error
  defp format_error(_error), do: "Could not update this video."
end
