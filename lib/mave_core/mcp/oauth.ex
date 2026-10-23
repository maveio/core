defmodule MaveCore.MCP.OAuth do
  @moduledoc """
  Space-scoped OAuth grants for remote MCP clients. Secrets are stored only as
  SHA-256 digests. Authorization codes and refresh tokens are consumed under a
  database lock; refresh-token reuse revokes the entire connection.
  """
  import Ecto.Query

  alias MaveCore.Accounts
  alias MaveCore.Accounts.User
  alias MaveCore.Ecto.LegacyShortUUID
  alias MaveCore.MCP.{Client, Config, Grant, Token}
  alias MaveCore.Repo
  alias MaveCore.Spaces.Space

  @access_seconds 3_600
  @refresh_seconds 30 * 24 * 60 * 60

  def register(params) when is_map(params) do
    with name when is_binary(name) <- params["client_name"],
         true <- String.trim(name) != "" and String.length(name) <= 100,
         false <- Regex.match?(~r/[\p{Cc}\p{Cf}]/u, name),
         uris when is_list(uris) and length(uris) in 1..10 <- params["redirect_uris"],
         true <- Enum.all?(uris, &redirect_uri?/1),
         "none" <- Map.get(params, "token_endpoint_auth_method", "none"),
         ["code"] <- Map.get(params, "response_types", ["code"]),
         true <-
           valid_grants?(Map.get(params, "grant_types", ["authorization_code", "refresh_token"])) do
      %Client{name: String.trim(name), redirect_uris: Enum.uniq(uris)} |> Repo.insert()
    else
      _ -> {:error, :invalid_client_metadata}
    end
  end

  def register(_), do: {:error, :invalid_client_metadata}

  def client_metadata(client) do
    %{
      client_id: client.id,
      client_name: client.name,
      client_id_issued_at: DateTime.to_unix(client.inserted_at),
      redirect_uris: client.redirect_uris,
      token_endpoint_auth_method: "none",
      grant_types: ["authorization_code", "refresh_token"],
      response_types: ["code"]
    }
  end

  def authorization_request(params) when is_map(params) do
    with %Client{} = client <- get_client(params["client_id"]),
         "code" <- params["response_type"],
         uri when is_binary(uri) <- params["redirect_uri"],
         true <- uri in client.redirect_uris,
         true <- params["resource"] == Config.resource_url(),
         "S256" <- params["code_challenge_method"],
         challenge when is_binary(challenge) <- params["code_challenge"],
         true <- Regex.match?(~r/\A[A-Za-z0-9_-]{43}\z/, challenge),
         true <- valid_state?(params["state"]),
         {:ok, scope} <- scope(Map.get(params, "scope", "mave:read")) do
      {:ok,
       %{
         client: client,
         redirect_uri: uri,
         resource: params["resource"],
         challenge: challenge,
         scope: scope,
         state: params["state"]
       }}
    else
      _ -> {:error, :invalid_request}
    end
  end

  def authorization_request(_), do: {:error, :invalid_request}

  def approve(request, %User{} = user, space_id) do
    case Enum.find(Accounts.list_user_spaces(user), &(&1.id == space_id)) do
      %Space{} = space ->
        code = secret()

        grant = %Grant{
          client_id: request.client.id,
          user_id: user.id,
          space_id: space.id,
          resource: request.resource,
          scope: request.scope,
          redirect_uri: request.redirect_uri,
          code_hash: digest(code),
          code_challenge: request.challenge,
          code_expires_at: DateTime.add(now(), 300, :second)
        }

        case Repo.insert(grant) do
          {:ok, _grant} -> {:ok, redirect_url(request, %{"code" => code})}
          {:error, _} -> {:error, :invalid_request}
        end

      _ ->
        {:error, :access_denied}
    end
  end

  def redirect_url(request, values) do
    uri = URI.parse(request.redirect_uri)
    values = if request.state, do: Map.put(values, "state", request.state), else: values
    query = URI.decode_query(uri.query || "") |> Map.merge(values) |> URI.encode_query()
    URI.to_string(%{uri | query: query})
  end

  def exchange(%{"grant_type" => "authorization_code"} = params) do
    transaction(fn ->
      with code when is_binary(code) <- params["code"],
           %Grant{} = grant <-
             Repo.one(from g in Grant, where: g.code_hash == ^digest(code), lock: "FOR UPDATE"),
           true <- grant.client_id == params["client_id"],
           true <-
             grant.resource == params["resource"] and grant.resource == Config.resource_url(),
           true <- grant.redirect_uri == params["redirect_uri"],
           true <- valid_verifier?(params["code_verifier"], grant.code_challenge),
           true <- active?(grant) and future?(grant.code_expires_at) do
        consume_code(grant)
      else
        _ -> {:error, :invalid_grant}
      end
    end)
  end

  def exchange(%{"grant_type" => "refresh_token"} = params) do
    transaction(fn ->
      with refresh when is_binary(refresh) <- params["refresh_token"],
           %Token{} = token <- Repo.get_by(Token, refresh_hash: digest(refresh)),
           %Grant{} = grant <- lock_grant(token.grant_id),
           true <- grant.client_id == params["client_id"],
           true <-
             grant.resource == params["resource"] and grant.resource == Config.resource_url(),
           true <- active?(grant),
           true <- Map.get(params, "scope", grant.scope) == grant.scope do
        rotate(grant, Repo.get!(Token, token.id))
      else
        _ -> {:error, :invalid_grant}
      end
    end)
  end

  def exchange(_), do: {:error, :unsupported_grant_type}

  def authenticate(access) when is_binary(access) and byte_size(access) <= 512 do
    with %Token{} = token <- Repo.get_by(Token, access_hash: digest(access)),
         true <- future?(token.access_expires_at) and is_nil(token.refreshed_at),
         %Grant{} = grant <- Repo.get(Grant, token.grant_id),
         true <- grant.resource == Config.resource_url() and active?(grant) do
      {:ok, Repo.preload(grant, [:space, :user, :client])}
    else
      _ -> {:error, :invalid_token}
    end
  end

  def authenticate(_), do: {:error, :invalid_token}

  def revoke_token(params) do
    with value when is_binary(value) <- params["token"],
         hash = digest(value),
         %Token{} = token <-
           Repo.one(from t in Token, where: t.access_hash == ^hash or t.refresh_hash == ^hash),
         %Grant{client_id: client_id} = grant <- Repo.get(Grant, token.grant_id),
         true <- client_id == params["client_id"] do
      revoke(grant)
    end

    :ok
  end

  def connections(%User{id: id}) do
    Repo.all(
      from g in Grant,
        where: g.user_id == ^id and is_nil(g.revoked_at) and not is_nil(g.consumed_at),
        order_by: [desc: g.inserted_at],
        preload: [:client, :space]
    )
  end

  def revoke_connection(%User{} = user, id) do
    case Enum.find(connections(user), &(&1.id == id)) do
      nil -> {:error, :not_found}
      grant -> revoke(grant)
    end
  end

  def can_write?(%Grant{scope: scope}), do: "mave:write" in String.split(scope)

  def prune_expired do
    cutoff = DateTime.add(now(), -86_400, :second)
    # Retain used refresh tokens until their original lifetime ends so reuse can
    # still be detected. Each invocation is bounded, including abandoned clients.
    expired_tokens =
      from t in Token, where: t.refresh_expires_at < ^cutoff, select: t.id, limit: 10_000

    Repo.delete_all(from t in Token, where: t.id in subquery(expired_tokens))

    grants =
      from g in Grant,
        as: :grant,
        where: g.code_expires_at < ^cutoff,
        where: not exists(from t in Token, where: t.grant_id == parent_as(:grant).id),
        select: g.id,
        limit: 10_000

    Repo.delete_all(from g in Grant, where: g.id in subquery(grants))
    client_cutoff = DateTime.add(now(), -90 * 86_400, :second)

    clients =
      from c in Client,
        as: :client,
        where: c.inserted_at < ^client_cutoff,
        where: not exists(from g in Grant, where: g.client_id == parent_as(:client).id),
        select: c.id,
        limit: 10_000

    Repo.delete_all(from c in Client, where: c.id in subquery(clients))
    :ok
  end

  defp consume_code(%Grant{consumed_at: nil} = grant) do
    Repo.update!(Ecto.Changeset.change(grant, consumed_at: now()))
    issue_tokens(grant, DateTime.add(now(), @refresh_seconds, :second))
  end

  defp consume_code(grant) do
    revoke(grant)
    {:error, :invalid_grant}
  end

  defp rotate(grant, %Token{refreshed_at: nil} = token) do
    if future?(token.refresh_expires_at) do
      Repo.update!(Ecto.Changeset.change(token, refreshed_at: now()))
      issue_tokens(grant, token.refresh_expires_at)
    else
      {:error, :invalid_grant}
    end
  end

  defp rotate(grant, _token) do
    revoke(grant)
    {:error, :invalid_grant}
  end

  defp issue_tokens(grant, refresh_expires_at) do
    access = secret()
    refresh = secret()

    Repo.insert!(%Token{
      grant_id: grant.id,
      access_hash: digest(access),
      refresh_hash: digest(refresh),
      access_expires_at: DateTime.add(now(), @access_seconds, :second),
      refresh_expires_at: refresh_expires_at
    })

    {:ok,
     %{
       access_token: access,
       refresh_token: refresh,
       token_type: "Bearer",
       expires_in: @access_seconds,
       scope: grant.scope
     }}
  end

  defp active?(%Grant{revoked_at: nil} = grant) do
    Accounts.can_access_space?(Repo.get(User, grant.user_id), Repo.get(Space, grant.space_id))
  end

  defp active?(_), do: false
  defp revoke(grant), do: Repo.update(Ecto.Changeset.change(grant, revoked_at: now()))
  defp lock_grant(id), do: Repo.one(from g in Grant, where: g.id == ^id, lock: "FOR UPDATE")

  defp get_client(value) when is_binary(value) do
    case LegacyShortUUID.cast(value) do
      {:ok, id} -> Repo.get(Client, id)
      _ -> nil
    end
  end

  defp get_client(_), do: nil

  defp redirect_uri?(value) when is_binary(value) and byte_size(value) <= 2_048 do
    uri = URI.parse(value)

    allowed_scheme =
      uri.scheme == "https" or
        (uri.scheme == "http" and uri.host in ["127.0.0.1", "localhost", "::1"])

    allowed_scheme and is_binary(uri.host) and uri.host != "" and
      is_nil(uri.userinfo) and is_nil(uri.fragment) and
      not Regex.match?(~r/[\x00-\x20\x7f\\]/, value)
  end

  defp redirect_uri?(_), do: false
  defp valid_state?(nil), do: true
  defp valid_state?(value), do: is_binary(value) and byte_size(value) <= 2_048

  defp valid_grants?(values) when is_list(values),
    do:
      "authorization_code" in values and
        Enum.all?(values, &(&1 in ["authorization_code", "refresh_token"]))

  defp valid_grants?(_), do: false

  defp scope(value) when is_binary(value) do
    scopes = String.split(value) |> Enum.uniq()

    if "mave:read" in scopes and Enum.all?(scopes, &(&1 in Config.scopes())),
      do: {:ok, Enum.sort(scopes) |> Enum.join(" ")},
      else: {:error, :invalid_scope}
  end

  defp scope(_), do: {:error, :invalid_scope}

  defp valid_verifier?(value, challenge) when is_binary(value) do
    Regex.match?(~r/\A[A-Za-z0-9._~-]{43,128}\z/, value) and
      Plug.Crypto.secure_compare(Base.url_encode64(digest(value), padding: false), challenge)
  end

  defp valid_verifier?(_, _), do: false
  defp secret, do: :crypto.strong_rand_bytes(32) |> Base.url_encode64(padding: false)
  defp digest(value), do: :crypto.hash(:sha256, value)
  defp now, do: DateTime.utc_now()
  defp future?(date), do: DateTime.compare(date, now()) == :gt

  defp transaction(fun) do
    case Repo.transaction(fun) do
      {:ok, result} -> result
      {:error, _} -> {:error, :invalid_grant}
    end
  end
end
