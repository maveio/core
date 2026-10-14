defmodule MaveCore.Playback.Password do
  @moduledoc "Password access to confirmed private media using revocable, video-scoped tokens."
  import Ecto.Query

  alias MaveCore.Embeds.Embed
  alias MaveCore.Embeds.Events
  alias MaveCore.Playback
  alias MaveCore.Repo
  alias MaveCore.Spaces.Space

  @salt "password-playback-v1"
  @ttl 14_400
  @max_bytes 1024

  def protected?(%Embed{} = embed),
    do: is_binary(embed.password_hash) or embed.password_protected

  # Keep hashes out of long-lived dashboard assigns, including error inspection.
  def for_dashboard(%Embed{} = embed),
    do: %{embed | password_protected: protected?(embed), password_hash: nil, password_revision: 0}

  def validate(space, params, embed \\ nil) do
    password = fetch_password(params)
    visibility = Map.get(params, "visibility", Map.get(params, :visibility))

    cond do
      invalid_input?(password) ->
        {:error, :invalid_password}

      password != :absent and not Playback.available?(space) ->
        {:error, :playback_unavailable}

      publishing_password?(visibility, password, embed) ->
        {:error, :password_requires_private}

      true ->
        :ok
    end
  end

  def creation_access(space, attrs, visibility) do
    with :ok <- validate(space, attrs) do
      case fetch_password(attrs) do
        password when is_binary(password) -> {:ok, :private, hash(password)}
        _ -> {:ok, visibility, nil}
      end
    end
  end

  def update(%Embed{} = embed, params) do
    case fetch_password(params) do
      :absent -> {:ok, embed}
      password -> update_password(embed, password, params)
    end
  end

  defp update_password(embed, password, params) do
    with :ok <- validate(Repo.get!(Space, embed.space_id), params, embed) do
      password_hash = if password, do: hash(password)

      Repo.transaction(fn -> persist_password(embed, password_hash, params) end)
      |> broadcast_update()
    end
  end

  defp persist_password(embed, password_hash, params) do
    space = Repo.one!(from(s in Space, where: s.id == ^embed.space_id, lock: "FOR UPDATE"))
    current = Repo.get!(Embed, embed.id)

    with true <- current.type == :video and is_nil(current.deleted_at),
         :ok <- validate(space, params, current),
         {:ok, updated} <-
           current
           |> Ecto.Changeset.change(
             password_hash: password_hash,
             password_revision: current.password_revision + 1
           )
           |> Repo.update(log: false),
         {:ok, updated} <- Playback.request_visibility(updated, :private) do
      updated
    else
      false -> Repo.rollback(:not_found)
      {:error, reason} -> Repo.rollback(reason)
    end
  end

  defp invalid_input?(password),
    do: password not in [:absent, nil] and not valid_password?(password)

  defp publishing_password?(visibility, password, embed),
    do:
      visibility in [:public, "public"] and
        (password != :absent or (not is_nil(embed) and protected?(embed)))

  def issue(%Embed{} = embed, password) do
    cond do
      not valid_password?(password) or not is_binary(embed.password_hash) ->
        {:error, :invalid_password}

      not Argon2.verify_pass(password, embed.password_hash) ->
        {:error, :invalid_password}

      not Playback.available?(embed.space) ->
        {:error, :playback_unavailable}

      not confirmed_private?(embed) ->
        {:error, :protection_pending}

      true ->
        expires_at = System.system_time(:second) + @ttl

        claims = %{
          embed_id: embed.id,
          space_id: embed.space_id,
          revision: embed.password_revision,
          expires_at: expires_at
        }

        {:ok,
         %{
           token: Phoenix.Token.sign(Playback.token_endpoint(), @salt, claims),
           expires_at: expires_at
         }}
    end
  end

  def issue(_embed, _password), do: {:error, :invalid_password}

  def authorize(token, %Embed{} = embed) do
    with {:ok, claims} <-
           Phoenix.Token.verify(Playback.token_endpoint(), @salt, token || "", max_age: @ttl),
         %{embed_id: id, space_id: space_id, revision: revision, expires_at: expires_at} <- claims,
         true <- id == embed.id and space_id == embed.space_id,
         # Always reload: callers may hold a pre-rotation dashboard/embed snapshot.
         %Embed{} = current <- Repo.get(Embed, id),
         true <- is_nil(current.deleted_at) and protected?(current),
         true <- current.password_revision == revision and confirmed_private?(current),
         true <- expires_at > System.system_time(:second) do
      {:ok, expires_at}
    else
      _ -> {:error, :unauthorized}
    end
  end

  defp confirmed_private?(embed),
    do: embed.playback_visibility == :private and embed.playback_status == :private

  defp valid_password?(password),
    do: is_binary(password) and byte_size(password) in 1..@max_bytes and String.valid?(password)

  defp hash(password), do: Argon2.hash_pwd_salt(password, argon2_type: 2)

  defp fetch_password(params),
    do: Map.get(params, "password", Map.get(params, :password, :absent))

  defp broadcast_update({:ok, embed} = result) do
    Events.broadcast_updated(embed.space_id, embed.id)
    result
  end

  defp broadcast_update(result), do: result
end
