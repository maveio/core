defmodule MaveCore.MCP.Tools do
  @moduledoc "Space-scoped MCP tools matching the video and collection commands in mave-cli."

  alias MaveCore.Embeds
  alias MaveCore.Embeds.Embed
  alias MaveCore.MCP.OAuth
  alias MaveCore.PublicApi

  def list(grant) do
    definitions()
    |> Enum.filter(fn tool -> tool.annotations.readOnlyHint or OAuth.can_write?(grant) end)
  end

  def call(grant, name, arguments) when is_map(arguments) do
    with tool when not is_nil(tool) <- Enum.find(list(grant), &(&1.name == name)),
         true <- valid_arguments?(arguments, tool.inputSchema) do
      {:ok, execute(grant, name, arguments)}
    else
      _ -> {:error, :invalid_params}
    end
  end

  def call(_, _, _), do: {:error, :invalid_params}

  defp definitions do
    id = %{type: "string", minLength: 1, maxLength: 80}
    name = %{type: "string", minLength: 1, maxLength: 255}

    collection = %{
      type: ["string", "null"],
      minLength: 1,
      maxLength: 80,
      description: "Collection ID, or null to move to the root."
    }

    pagination = %{
      "page" => %{type: "integer", minimum: 1, maximum: 1_000_000},
      "per_page" => %{type: "integer", minimum: 1, maximum: 100}
    }

    update = %{"id" => id, "name" => name, "collection" => collection}

    deletion = %{
      "id" => id,
      "confirm" => %{
        type: "boolean",
        const: true,
        description: "Set true only after the user approves this deletion."
      }
    }

    [
      tool(
        "mave_get_connection",
        "Show the connected Mave space and granted permissions.",
        %{},
        []
      ),
      tool(
        "mave_list_videos",
        "List videos in the authorized space, with pagination and optional collection/upload filters.",
        Map.merge(pagination, %{
          "collection" => id,
          "uploaded" => %{type: "boolean"},
          "show_collections" => %{type: "boolean"}
        }),
        []
      ),
      tool(
        "mave_get_video",
        "Read a video's metadata and available renditions. Poll this after a URL import to check processing.",
        %{"id" => id},
        ["id"]
      ),
      tool(
        "mave_create_video",
        "Create a video, optionally importing a public HTTP(S) input_url. Processing continues asynchronously; a successful call does not mean playback is ready.",
        %{
          "name" => name,
          "collection" => id,
          "input_url" => %{type: "string", minLength: 1, maxLength: 2_048}
        },
        [],
        :create
      ),
      tool(
        "mave_update_video",
        "Rename or move a video. Supply name or collection; null collection moves it to the root.",
        update,
        ["id"],
        :update
      ),
      tool(
        "mave_delete_video",
        "Delete a video in the authorized space. Requires explicit user confirmation.",
        deletion,
        ["id", "confirm"],
        :delete
      ),
      tool("mave_list_collections", "List collections in the authorized space.", pagination, []),
      tool(
        "mave_create_collection",
        "Create a named collection, optionally inside another collection.",
        %{"name" => name, "collection" => id},
        ["name"],
        :create
      ),
      tool(
        "mave_update_collection",
        "Rename or move a collection. Supply name or collection; null collection moves it to the root.",
        update,
        ["id"],
        :update
      ),
      tool(
        "mave_delete_collection",
        "Delete a collection in the authorized space. Requires explicit user confirmation.",
        deletion,
        ["id", "confirm"],
        :delete
      )
    ]
  end

  defp tool(name, description, properties, required, operation \\ :read) do
    %{
      name: name,
      description: description,
      inputSchema: %{
        type: "object",
        properties: properties,
        required: required,
        additionalProperties: false
      },
      annotations: %{
        readOnlyHint: operation == :read,
        destructiveHint: operation in [:update, :delete],
        idempotentHint: operation in [:read, :update, :delete],
        openWorldHint: true
      }
    }
  end

  defp valid_arguments?(args, schema) do
    Enum.all?(schema.required, &Map.has_key?(args, &1)) and
      Enum.all?(args, fn {key, value} ->
        case Map.get(schema.properties, key) do
          nil -> false
          property -> valid_value?(value, property)
        end
      end)
  end

  defp valid_value?(nil, %{type: ["string", "null"]}), do: true

  defp valid_value?(value, %{type: ["string", "null"]} = spec),
    do: valid_value?(value, %{spec | type: "string"})

  defp valid_value?(value, %{type: "string"} = spec),
    do:
      is_binary(value) and String.length(String.trim(value)) >= spec.minLength and
        String.length(value) <= spec.maxLength

  defp valid_value?(value, %{type: "integer"} = spec),
    do: is_integer(value) and value >= spec.minimum and value <= spec.maximum

  defp valid_value?(value, %{const: expected}), do: value == expected
  defp valid_value?(value, %{type: "boolean"}), do: is_boolean(value)

  defp execute(grant, "mave_get_connection", _args),
    do: success(%{space_id: grant.space.id, space_hash: grant.space.hash, scope: grant.scope})

  defp execute(%{space: space}, "mave_list_videos", args) do
    case PublicApi.resolve_collection_id(space, args["collection"]) do
      {:ok, collection_id} ->
        opts =
          pagination(args) ++
            [
              collection_id: collection_id,
              uploaded: args["uploaded"],
              show_collections: args["show_collections"] == true
            ]

        data =
          Enum.map(PublicApi.list_videos(space, opts), fn
            %Embed{type: :collection} = embed -> PublicApi.collection_response(space, embed)
            embed -> PublicApi.video_response(space, embed)
          end)

        success(
          PublicApi.list_response(
            data,
            opts[:page],
            opts[:per_page],
            PublicApi.count_videos(space, opts)
          )
        )

      {:error, _} ->
        failure("This collection does not belong to the connected space.")
    end
  end

  defp execute(%{space: space}, "mave_list_collections", args) do
    opts = pagination(args)

    data =
      Enum.map(PublicApi.list_collections(space, opts), &PublicApi.collection_response(space, &1))

    success(
      PublicApi.list_response(
        data,
        opts[:page],
        opts[:per_page],
        PublicApi.count_collections(space, opts)
      )
    )
  end

  defp execute(%{space: space}, "mave_get_video", args) do
    case PublicApi.get_embed(space, args["id"]) do
      %Embed{type: :video} = embed -> success(PublicApi.video_response(space, embed))
      _ -> failure("Video not found in the connected space.")
    end
  end

  defp execute(%{space: space}, "mave_create_video", args) do
    with :ok <- validate_input(args["input_url"]),
         {:ok, parent} <- PublicApi.resolve_collection_embed(space, args["collection"]),
         {:ok, embed} <-
           Embeds.create_video_embed(space, %{
             name: args["name"],
             parent_folder_id: parent && parent.id
           }),
         :ok <- start_import(space, embed, args["input_url"]) do
      success(PublicApi.video_response(space, PublicApi.get_embed(space, embed.hash)))
    else
      {:error, _} ->
        failure(
          "Could not create the video. Check the collection, public input URL, and space limits before retrying."
        )
    end
  end

  defp execute(%{space: space}, "mave_create_collection", args) do
    with {:ok, parent} <- PublicApi.resolve_collection_embed(space, args["collection"]),
         {:ok, embed} <-
           Embeds.create_folder_embed(space, %{
             name: args["name"],
             parent_folder_id: parent && parent.id
           }) do
      success(PublicApi.collection_response(space, PublicApi.get_embed(space, embed.hash)))
    else
      {:error, _} -> failure("Could not create the collection in the connected space.")
    end
  end

  defp execute(%{space: space}, name, args)
       when name in ["mave_update_video", "mave_update_collection"] do
    type = if name == "mave_update_video", do: :video, else: :collection

    with %Embed{type: ^type} = embed <- PublicApi.get_embed(space, args["id"]),
         true <- Map.has_key?(args, "name") or Map.has_key?(args, "collection"),
         {:ok, parent} <- PublicApi.resolve_collection_embed(space, args["collection"]),
         {:ok, _} <- update_embed(embed, parent, args) do
      success(serialize(space, PublicApi.get_embed(space, embed.hash)))
    else
      _ ->
        failure(
          "Could not update this item. Supply name or collection and use IDs from the connected space."
        )
    end
  end

  defp execute(%{space: space}, name, args)
       when name in ["mave_delete_video", "mave_delete_collection"] do
    type = if name == "mave_delete_video", do: :video, else: :collection

    with %Embed{type: ^type} = embed <- PublicApi.get_embed(space, args["id"]),
         {:ok, _} <- Embeds.delete_embed(embed) do
      success(%{deleted: true, id: args["id"]})
    else
      _ -> failure("Item not found or could not be deleted in the connected space.")
    end
  end

  defp update_embed(embed, parent, args) do
    MaveCore.Repo.transaction(fn ->
      with {:ok, embed} <- maybe_rename(embed, args),
           {:ok, embed} <- maybe_move(embed, parent, args) do
        embed
      else
        {:error, reason} -> MaveCore.Repo.rollback(reason)
      end
    end)
  end

  defp maybe_rename(embed, %{"name" => name}), do: Embeds.rename_embed(embed, name)
  defp maybe_rename(embed, _), do: {:ok, embed}
  defp maybe_move(embed, parent, %{"collection" => _}), do: Embeds.move_embed(embed, parent)
  defp maybe_move(embed, _, _), do: {:ok, embed}
  defp serialize(space, %Embed{type: :video} = embed), do: PublicApi.video_response(space, embed)
  defp serialize(space, embed), do: PublicApi.collection_response(space, embed)
  defp validate_input(nil), do: :ok
  defp validate_input(url), do: PublicApi.validate_input_url(url)
  defp start_import(_, _, nil), do: :ok
  defp start_import(space, embed, url), do: PublicApi.start_input_url_upload(space, embed, url)

  defp pagination(args),
    do: [page: Map.get(args, "page", 1), per_page: Map.get(args, "per_page", 15)]

  defp success(data),
    do: %{
      content: [%{type: "text", text: Jason.encode!(data)}],
      structuredContent: data,
      isError: false
    }

  defp failure(message), do: %{content: [%{type: "text", text: message}], isError: true}
end
