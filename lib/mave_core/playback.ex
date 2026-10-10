defmodule MaveCore.Playback do
  @moduledoc """
  Per-embed playback access using API JWTs and internal dashboard tokens.

  Deployments supply a storage adapter implementing `MaveCore.Playback.Adapter`.
  """
  import Ecto.Query

  alias MaveCore.Embeds
  alias MaveCore.Embeds.Embed
  alias MaveCore.PublicApi
  alias MaveCore.Repo
  alias MaveCore.Spaces
  alias MaveCore.Spaces.Space
  alias MaveCore.Workers.PlaybackVisibilityWorker
  alias MaveCoreWeb.Endpoint

  @salt "media-playback-v1"
  @dashboard_ttl 86_400

  def adapter, do: Application.get_env(:mave_core, :playback_adapter)

  defp token_endpoint do
    module = adapter()

    if module && Code.ensure_loaded?(module) && function_exported?(module, :token_endpoint, 0),
      do: module.token_endpoint(),
      else: Endpoint
  end

  def available?(%Space{} = space) do
    case adapter() do
      nil -> false
      module -> module.available?(space)
    end
  end

  def protected?(%Embed{playback_visibility: visibility, playback_status: status}),
    do: visibility == :private or status != :public

  def validate_visibility(_space, visibility) when visibility in [:public, "public"], do: :ok

  def validate_visibility(space, visibility) when visibility in [:private, "private"] do
    if available?(space), do: :ok, else: {:error, :playback_unavailable}
  end

  def validate_visibility(_space, _visibility), do: {:error, :invalid_visibility}

  # Creation holds the space lock. Finish storage protection before allowing uploads.
  def initialize_visibility(embed, visibility) when visibility in [:public, "public"],
    do: {:ok, embed}

  def initialize_visibility(embed, visibility) when visibility in [:private, "private"] do
    embed = Repo.preload(embed, [:space, :asset])

    with :ok <- adapter().apply_visibility(embed, :private) do
      embed
      |> Ecto.Changeset.change(playback_visibility: :private, playback_status: :private)
      |> Repo.update()
    end
  end

  def request_visibility(%Embed{} = embed, visibility) when visibility in [:public, :private] do
    Repo.transaction(fn ->
      space = Repo.one!(from(s in Space, where: s.id == ^embed.space_id, lock: "FOR UPDATE"))
      current = Repo.get!(Embed, embed.id)

      if current.type != :video or not is_nil(current.deleted_at) or
           (visibility == :private and not available?(space)) or is_nil(adapter()) do
        Repo.rollback(:playback_unavailable)
      end

      if current.playback_status == visibility do
        current
      else
        updated =
          current
          |> Ecto.Changeset.change(
            playback_status: if(visibility == :private, do: :protecting, else: :publishing)
          )
          |> Repo.update!()

        %{embed_id: updated.id}
        |> PlaybackVisibilityWorker.new()
        |> Oban.insert!()

        updated
      end
    end)
  end

  # Call only after dashboard membership authorization; never from a public route.
  def dashboard_session(%Embed{} = embed),
    do: session(embed, System.system_time(:second) + @dashboard_ttl)

  def authorize(token, %Embed{} = embed) do
    case authorize_dashboard(token, embed) do
      {:ok, expires_at} -> {:ok, expires_at}
      _ -> authorize_jwt(token, embed)
    end
  end

  defp authorize_jwt(token, embed) do
    with {:ok, %{claims: claims, key: key, space: space}} <- Spaces.validate_api_jwt(token, false),
         true <- space.id == embed.space_id and is_nil(key.purpose),
         true <- is_nil(claims["exp"]) or claims["exp"] > System.system_time(:second),
         true <- scope_allows?(space, embed, claims["sub"]),
         true <- is_nil(claims["collection"]) or scope_allows?(space, embed, claims["collection"]) do
      # Storage URLs remain bounded, even when the customer's JWT has no expiry.
      {:ok,
       min(
         Map.get(claims, "exp", System.system_time(:second) + @dashboard_ttl),
         System.system_time(:second) + @dashboard_ttl
       )}
    else
      _ -> {:error, :unauthorized}
    end
  end

  defp authorize_dashboard(token, %Embed{} = embed) do
    with {:ok, %{embed_id: id, space_id: space_id, expires_at: expires_at}} <-
           Phoenix.Token.verify(token_endpoint(), @salt, token || "", max_age: @dashboard_ttl),
         true <- id == embed.id and space_id == embed.space_id,
         true <- expires_at > System.system_time(:second) do
      {:ok, expires_at}
    else
      _ -> {:error, :unauthorized}
    end
  end

  defp session(embed, expires_at) do
    claims = %{embed_id: embed.id, space_id: embed.space_id, expires_at: expires_at}

    %{
      token: Phoenix.Token.sign(token_endpoint(), @salt, claims),
      expires_at: expires_at,
      media_base_path: "/playback/media/#{embed.id}"
    }
  end

  defp scope_allows?(space, embed, scope) when is_binary(scope) do
    scope in [space.id, space.hash, embed.id, embed.hash, space.hash <> embed.hash] or
      PublicApi.jwt_scoped_video_deletable?(space, embed, collection_scope(space, scope))
  end

  defp scope_allows?(_space, _embed, _scope), do: false

  defp collection_scope(space, scope) do
    case MaveCore.LegacyShortUUID.cast(scope) do
      {:ok, id} ->
        Repo.one(
          from(e in Embed,
            where:
              e.id == ^id and e.space_id == ^space.id and e.type == :collection and
                is_nil(e.deleted_at)
          )
        ) || scope

      _ ->
        scope
    end
  end

  def get_embed(identifier) when is_binary(identifier) and byte_size(identifier) == 15 do
    with {:ok, %{space_hash: space_hash, embed_hash: embed_hash}} <-
           MaveCore.EmbedId.split(identifier),
         %Embed{type: :video} = embed <- Embeds.get_embed_by_hashes(space_hash, embed_hash) do
      embed
    else
      _ -> nil
    end
  end

  def get_embed(id) do
    case Repo.get(Embed, id) do
      %Embed{type: :video, deleted_at: nil} = embed ->
        Embeds.get_embed_by_hashes(Repo.get!(Space, embed.space_id).hash, embed.hash)

      _ ->
        nil
    end
  rescue
    Ecto.Query.CastError -> nil
  end
end
