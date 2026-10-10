defmodule MaveCore.Spaces do
  @moduledoc """
  Spaces context for dashboard settings and space-level configuration.
  """
  import Ecto.Query, only: [from: 2]
  require Logger

  alias MaveCore.AccountDeletion
  alias MaveCore.Accounts.User
  alias MaveCore.Embeds.Embed
  alias MaveCore.LegacyShortUUID
  alias MaveCore.Media.Storage
  alias MaveCore.PublicApi
  alias MaveCore.PublicHttpUrl
  alias MaveCore.Repo
  alias MaveCore.SharedStorageSpace
  alias MaveCore.StorageProfiles
  alias MaveCore.UsageLimits

  alias MaveCore.Spaces.{
    Domain,
    Events,
    Key,
    Membership,
    MembershipInvite,
    Space,
    Webhook,
    WebhookDelivery
  }

  alias MaveCore.Workers.WebhookDeliveryWorker

  @default_webhook_max_attempts 8
  @internal_key_descriptions %{dashboard_uploads: "Dashboard uploads"}
  @jwt_time_claim_leeway_seconds 60
  @webhook_response_body_limit 16 * 1024
  @webhook_response_body_truncated "\n[mave: response body truncated]"
  @webhook_response_header_count_limit 64
  @webhook_response_header_field_limit 2 * 1024
  @webhook_response_header_name_limit 128
  @webhook_response_headers_limit 16 * 1024
  @webhook_response_headers_json_limit 20 * 1024
  @webhook_response_truncated_header "x-mave-response-truncated"

  @doc """
  Returns the storage profile for a space.
  Falls back to the default storage profile if space not found or no repo configured.
  """
  def get_storage_profile(space_hash) do
    normalized_space_hash = normalize_space_hash(space_hash)

    profile =
      case Application.get_env(:mave_core, :spaces_repo) do
        nil -> nil
        repo -> storage_profile_for_hash(repo, normalized_space_hash)
      end

    profile || fallback_storage_profile(normalized_space_hash)
  end

  @doc """
  Legacy compatibility alias for the storage-profile lookup.
  """
  def get_region(space_hash), do: get_storage_profile(space_hash)

  def get_space_by_hash(space_hash) when is_binary(space_hash) do
    normalized_space_hash = normalize_space_hash(space_hash)

    from(s in Space,
      where: s.hash == ^normalized_space_hash and is_nil(s.deleted_at),
      limit: 2
    )
    |> Repo.all()
    |> unique_result()
  end

  def sync_bucket_access_for_space_hash(space_hash, storage_profile \\ nil)

  def sync_bucket_access_for_space_hash(space_hash, storage_profile) when is_binary(space_hash) do
    sync_domain_cors_by_hash(space_hash, storage_profile)
  end

  def list_domains(%Space{id: space_id}) do
    from(d in Domain,
      where: d.space_id == ^space_id,
      order_by: [asc: d.inserted_at]
    )
    |> Repo.all()
  end

  def change_domain(%Domain{} = domain, attrs \\ %{}) do
    Domain.changeset(domain, attrs)
  end

  def create_domain(%Space{} = space, attrs) when is_map(attrs) do
    attrs =
      attrs
      |> stringify_keys()
      |> Map.put("space_id", space.id)

    %Domain{}
    |> Domain.changeset(attrs)
    |> Repo.insert()
    |> case do
      {:ok, domain} ->
        sync_domain_cors(space.id)
        Events.broadcast_updated(space.id)
        {:ok, domain}

      {:error, changeset} ->
        {:error, changeset}
    end
  end

  def get_domain_for_space(%Space{id: space_id}, domain_id) when is_binary(domain_id) do
    from(d in Domain,
      where: d.id == ^domain_id and d.space_id == ^space_id
    )
    |> Repo.one()
  end

  def delete_domain(%Domain{} = domain) do
    case Repo.delete(domain) do
      {:ok, deleted_domain} ->
        sync_domain_cors(domain.space_id)
        Events.broadcast_updated(domain.space_id)
        {:ok, deleted_domain}

      {:error, changeset} ->
        {:error, changeset}
    end
  end

  def list_keys(%Space{id: space_id}) do
    from(k in Key,
      where: k.space_id == ^space_id,
      order_by: [desc: k.inserted_at]
    )
    |> Repo.all()
  end

  def list_user_managed_keys(%Space{id: space_id}) do
    from(k in Key,
      where: k.space_id == ^space_id and is_nil(k.purpose),
      order_by: [desc: k.inserted_at]
    )
    |> Repo.all()
  end

  def list_memberships(%Space{id: space_id}) do
    from(m in Membership,
      where: m.space_id == ^space_id,
      left_join: u in assoc(m, :user),
      left_join: i in assoc(m, :invite),
      left_join: iu in assoc(i, :user),
      left_join: owner_space in assoc(m, :owner_space),
      where: is_nil(u.id) or is_nil(u.deleted_at),
      where: is_nil(iu.id) or is_nil(iu.deleted_at),
      preload: [user: u, invite: {i, user: iu}, owner_space: {owner_space, [:domains]}],
      order_by: [asc: m.inserted_at]
    )
    |> Repo.all()
  end

  def get_membership_for_space(%Space{id: space_id}, membership_id)
      when is_binary(membership_id) do
    from(m in Membership,
      where: m.id == ^membership_id and m.space_id == ^space_id,
      preload: [:user, owner_space: [:domains], invite: [:user]]
    )
    |> Repo.one()
  end

  def get_membership_invite(invite_id) when is_binary(invite_id) do
    from(m in Membership,
      join: i in assoc(m, :invite),
      join: s in assoc(m, :space),
      left_join: u in assoc(m, :user),
      left_join: iu in assoc(i, :user),
      where: i.id == ^invite_id and is_nil(s.deleted_at),
      preload: [space: s, user: u, invite: {i, user: iu}]
    )
    |> Repo.one()
  end

  def add_member_by_email(%Space{} = space, email, opts \\ %{})
      when is_binary(email) and is_map(opts) do
    role = Map.get(opts, :role, "member")
    normalized_email = email |> String.trim() |> String.downcase()

    with {:ok, normalized_email} <- validate_member_email(normalized_email),
         :ok <- ensure_can_add_member(space, role),
         %User{} = user <- get_active_user_by_email(normalized_email),
         false <- membership_exists?(space.id, user.id),
         {:ok, membership} <-
           %Membership{}
           |> Membership.create_changeset(%{space_id: space.id, user_id: user.id, role: role})
           |> Repo.insert() do
      Events.broadcast_updated(space.id)
      {:ok, Repo.preload(membership, [:user])}
    else
      {:error, reason} ->
        {:error, reason}

      nil ->
        {:error, :user_not_found}

      true ->
        {:error, :already_member}
    end
  end

  def create_membership_invite(%Space{} = space, %User{} = created_by, email, opts \\ %{})
      when is_binary(email) and is_map(opts) do
    role = Map.get(opts, :role, "member")
    normalized_email = email |> String.trim() |> String.downcase()
    invitee_user = get_active_user_by_email(normalized_email)

    with {:ok, normalized_email} <- validate_member_email(normalized_email),
         :ok <- ensure_can_add_member(space, role),
         false <- pending_membership_exists?(space.id, normalized_email, invitee_user),
         false <- membership_exists?(space.id, invitee_user && invitee_user.id),
         {:ok, membership} <-
           create_membership_invite_transaction(
             space,
             created_by,
             normalized_email,
             invitee_user,
             role
           ) do
      Events.broadcast_updated(space.id)
      {:ok, membership}
    else
      {:error, reason} ->
        {:error, reason}

      true ->
        {:error, :already_member}
    end
  end

  def accept_membership_invite(%Membership{} = membership, %User{} = user) do
    membership = Repo.preload(membership, [:space, invite: [:user]])

    with %MembershipInvite{} = invite <- membership.invite,
         true <- is_nil(invite.accepted_at),
         true <- can_accept_invite?(invite, user),
         {:ok, accepted_membership} <-
           accept_membership_invite_transaction(invite, membership, user) do
      Events.broadcast_updated(accepted_membership.space_id)
      {:ok, accepted_membership}
    else
      nil -> {:error, :not_found}
      false -> {:error, :not_allowed}
      {:error, reason} -> {:error, reason}
    end
  end

  def remove_member(%Space{} = space, membership_id, opts \\ %{})
      when is_binary(membership_id) and is_map(opts) do
    case get_membership_for_space(space, membership_id) do
      nil ->
        {:error, :not_found}

      %Membership{role: role} when role in ["owner", :owner] ->
        {:error, :cannot_remove_owner}

      %Membership{} = membership ->
        if membership.invite do
          Repo.delete(membership.invite)
        end

        membership
        |> Repo.delete()
        |> maybe_broadcast_space_updated(space.id)
        |> tap(fn
          {:ok, _} -> Events.broadcast_access_changed()
          _ -> :ok
        end)
    end
  end

  def create_key(%Space{id: space_id}, attrs \\ %{}) when is_map(attrs) do
    insert_key(%Key{}, space_id, attrs)
  end

  def create_cli_key(
        %Space{id: space_id},
        %MaveCore.CliAuthorizations.Authorization{
          status: :approved,
          space_id: space_id,
          client_metadata: metadata
        }
      ) do
    insert_key(%Key{cli_metadata: metadata}, space_id, %{description: "Mave CLI"})
  end

  defp insert_key(key, space_id, attrs) do
    attrs =
      attrs
      |> stringify_keys()
      |> Map.take(["description", "access_level"])
      |> normalize_key_description()
      |> generated_key_attrs(space_id)

    key
    |> Key.changeset(attrs)
    |> Repo.insert()
    |> maybe_broadcast_space_updated(space_id)
  end

  def ensure_key(%Space{} = space, attrs \\ %{}) when is_map(attrs) do
    case Enum.find(list_user_managed_keys(space), &key_can_write?/1) do
      %Key{} = key ->
        {:ok, key}

      nil ->
        create_key(space, attrs)
        |> fallback_to_existing_key(space)
    end
  end

  def ensure_internal_key(%Space{} = space, purpose)
      when is_map_key(@internal_key_descriptions, purpose) do
    case get_internal_key(space, purpose) do
      %Key{access_level: :read_write} = key ->
        {:ok, key}

      %Key{} = key ->
        set_key_access_level(key, :read_write)

      nil ->
        create_internal_key(space, purpose)
        |> fallback_to_internal_key(space, purpose)
    end
  end

  defp create_internal_key(%Space{id: space_id}, purpose) do
    attrs =
      %{
        "description" => Map.fetch!(@internal_key_descriptions, purpose),
        "purpose" => purpose
      }
      |> generated_key_attrs(space_id)

    %Key{}
    |> Key.changeset(attrs)
    |> Repo.insert()
    |> maybe_broadcast_space_updated(space_id)
  end

  defp fallback_to_internal_key({:ok, %Key{} = key}, _space, _purpose), do: {:ok, key}

  defp fallback_to_internal_key({:error, _reason} = error, %Space{} = space, purpose) do
    case get_internal_key(space, purpose) do
      %Key{access_level: :read_write} = key -> {:ok, key}
      %Key{} = key -> set_key_access_level(key, :read_write)
      nil -> error
    end
  end

  defp fallback_to_existing_key({:ok, %Key{} = key}, _space), do: {:ok, key}

  defp fallback_to_existing_key({:error, _reason} = error, %Space{} = space) do
    case Enum.find(list_user_managed_keys(space), &key_can_write?/1) do
      %Key{} = key -> {:ok, key}
      nil -> error
    end
  end

  def key_can_write?(%Key{access_level: :read_write}), do: true
  def key_can_write?(_key), do: false

  def set_key_access_level(%Key{} = key, access_level) do
    update_key(key, %{access_level: access_level})
  end

  def make_key_read_only(%Key{} = key) do
    set_key_access_level(key, :read_only)
  end

  def change_key(%Key{} = key, attrs \\ %{}) when is_map(attrs) do
    attrs =
      attrs
      |> stringify_keys()
      |> Map.take(["description", "access_level"])
      |> normalize_key_description()

    Key.settings_changeset(key, attrs)
  end

  def update_key(%Key{} = key, attrs) when is_map(attrs) do
    key
    |> change_key(attrs)
    |> Repo.update()
    |> maybe_broadcast_space_updated(key.space_id)
  end

  def display_api_key(key, secret), do: "#{key}:#{secret}" |> Base.encode64()

  def get_key_by_identifier(key_id) when is_binary(key_id) do
    from(k in Key,
      join: s in assoc(k, :space),
      where: k.key == ^key_id and is_nil(s.deleted_at),
      preload: [space: s]
    )
    |> Repo.one()
  end

  def valid_secret?(%Key{secret: stored_secret}, secret)
      when is_binary(stored_secret) and is_binary(secret) and
             byte_size(stored_secret) == byte_size(secret) do
    Plug.Crypto.secure_compare(stored_secret, secret)
  end

  def valid_secret?(_key, _secret), do: false

  def update_last_used(%Key{} = key) do
    key
    |> Key.update_changeset(%{
      last_used_at: DateTime.utc_now() |> DateTime.truncate(:microsecond)
    })
    |> Repo.update()
  end

  def authenticate_api_key(key_id, secret)
      when is_binary(key_id) and is_binary(secret) do
    with %Key{} = key <- get_key_by_identifier(key_id),
         true <- valid_secret?(key, secret),
         {:ok, %Key{} = key} <- update_last_used(key),
         %Space{} = space <- key.space do
      {:ok, key, space}
    else
      _ -> :error
    end
  end

  def validate_api_jwt(jwt_string, mark_use \\ true)

  def validate_api_jwt(jwt_string, mark_use) when is_binary(jwt_string) do
    with {:ok, %{"sub" => sub} = claims} <- peek_jwt_claims(jwt_string),
         :ok <- validate_jwt_time_claims(claims),
         {:ok, %Key{} = key, %Space{} = space} <- matching_jwt_space_and_key(sub, jwt_string),
         {:ok, %Key{} = key} <- maybe_update_jwt_key_last_used(key, mark_use) do
      {:ok, %{claims: claims, key: key, space: space}}
    else
      _error -> {:error, "Invalid JWT (sub is required)"}
    end
  end

  def validate_api_jwt(_jwt_string, _mark_use), do: {:error, "Invalid JWT (sub is required)"}

  def get_key_for_space(%Space{id: space_id}, key_id) when is_binary(key_id) do
    from(k in Key,
      where: k.id == ^key_id and k.space_id == ^space_id
    )
    |> Repo.one()
  end

  def get_key_for_space_hash(space_hash, key_id)
      when is_binary(space_hash) and is_binary(key_id) do
    normalized_space_hash = normalize_space_hash(space_hash)

    from(k in Key,
      join: s in assoc(k, :space),
      where:
        k.id == ^key_id and s.hash == ^normalized_space_hash and
          is_nil(s.deleted_at),
      preload: [space: s]
    )
    |> Repo.one()
  end

  def get_user_managed_key_for_space(%Space{id: space_id}, key_id) when is_binary(key_id) do
    from(k in Key,
      where: k.id == ^key_id and k.space_id == ^space_id and is_nil(k.purpose)
    )
    |> Repo.one()
  end

  def delete_key(%Key{} = key) do
    key
    |> Repo.delete()
    |> maybe_broadcast_space_updated(key.space_id)
  end

  def list_webhooks(%Space{id: space_id}) do
    from(w in Webhook,
      where: w.space_id == ^space_id,
      order_by: [desc: w.inserted_at]
    )
    |> Repo.all()
  end

  def change_webhook(%Webhook{} = webhook, attrs \\ %{}) do
    Webhook.changeset(webhook, attrs)
  end

  def create_webhook(%Space{} = space, attrs) when is_map(attrs) do
    attrs =
      attrs
      |> stringify_keys()
      |> Map.merge(%{
        "space_id" => space.id,
        "secret" => "whsec_#{LegacyShortUUID.generate()}",
        "enabled" => true,
        "enabled_events" => Webhook.mave_events()
      })

    %Webhook{}
    |> Webhook.changeset(attrs)
    |> Repo.insert()
    |> maybe_broadcast_space_updated(space.id)
  end

  def get_webhook_for_space(%Space{id: space_id}, webhook_id) when is_binary(webhook_id) do
    from(w in Webhook,
      where: w.id == ^webhook_id and w.space_id == ^space_id
    )
    |> Repo.one()
  end

  def update_webhook(%Webhook{} = webhook, attrs) when is_map(attrs) do
    webhook
    |> Webhook.changeset(attrs)
    |> Repo.update()
    |> maybe_broadcast_space_updated(webhook.space_id)
  end

  def toggle_webhook(%Webhook{} = webhook) do
    update_webhook(webhook, %{enabled: !webhook.enabled})
  end

  def delete_webhook(%Webhook{} = webhook) do
    webhook
    |> Repo.delete()
    |> maybe_broadcast_space_updated(webhook.space_id)
  end

  def list_webhook_deliveries(%Space{id: space_id}, opts \\ []) do
    limit = Keyword.get(opts, :limit, 50)

    from(d in WebhookDelivery,
      where: d.space_id == ^space_id,
      order_by: [desc: d.inserted_at],
      preload: [:webhook],
      limit: ^limit
    )
    |> Repo.all()
  end

  def enqueue_webhook_event(%Space{} = space, event_type, payload \\ %{}, opts \\ %{})
      when is_map(payload) and is_map(opts) do
    with {:ok, normalized_event_type} <- normalize_event_type(event_type) do
      webhooks =
        from(w in Webhook,
          where: w.space_id == ^space.id and w.enabled == true,
          where: ^normalized_event_type in w.enabled_events,
          order_by: [desc: w.inserted_at]
        )
        |> Repo.all()

      enqueue? = Map.get(opts, :enqueue, true)

      deliveries =
        Enum.reduce(
          webhooks,
          [],
          &create_webhook_delivery(&1, &2, space, normalized_event_type, payload, enqueue?)
        )
        |> Enum.reverse()

      {:ok, deliveries}
    end
  end

  def enqueue_webhook_event_by_hash(
        space_hash,
        embed_hash,
        event_type,
        payload \\ %{},
        opts \\ %{}
      )
      when is_binary(space_hash) and is_binary(embed_hash) and is_map(payload) and is_map(opts) do
    _ = payload

    with %Embed{space: %Space{} = space} = embed <-
           get_embed_by_space_and_embed_hashes(space_hash, embed_hash),
         {:ok, deliveries} <- enqueue_webhook_event_for_embed(space, embed, event_type, opts) do
      {:ok, deliveries}
    else
      nil -> {:error, :not_found}
      {:error, reason} -> {:error, reason}
    end
  end

  def enqueue_webhook_event_for_embed(
        %Space{} = space,
        %Embed{} = embed,
        event_type,
        opts \\ %{}
      )
      when is_map(opts) do
    space = ensure_webhook_space(space, embed)
    payload = webhook_embed_payload(space, embed, event_type)

    enqueue_webhook_event(space, event_type, payload, opts)
  end

  def process_webhook_delivery(delivery_id, opts \\ %{})
      when is_binary(delivery_id) and is_map(opts) do
    max_attempts = Map.get(opts, :max_attempts, @default_webhook_max_attempts)

    case get_delivery_with_webhook(delivery_id) do
      nil ->
        {:ok, :not_found}

      %WebhookDelivery{state: state} when state in [:succeeded, :canceled] ->
        {:ok, state}

      %WebhookDelivery{} = delivery ->
        do_process_webhook_delivery(delivery, max_attempts)
    end
  end

  def update_space_features(%Space{} = space, attrs) when is_map(attrs) do
    attrs =
      attrs
      |> stringify_keys()
      |> Map.take(["hotlink_protection_enabled"])

    space
    |> Space.features_changeset(attrs)
    |> Repo.update()
    |> case do
      {:ok, updated_space} ->
        if Map.has_key?(attrs, "hotlink_protection_enabled") do
          sync_domain_cors(updated_space.id)
        end

        Events.broadcast_updated(updated_space.id)
        {:ok, updated_space}

      {:error, changeset} ->
        {:error, changeset}
    end
  end

  def update_space_processing(%Space{} = space, attrs) when is_map(attrs) do
    attrs =
      attrs
      |> stringify_keys()
      |> Map.take(["default_flow_template"])

    space
    |> Space.processing_changeset(attrs)
    |> Repo.update()
    |> maybe_broadcast_space_updated(space.id)
  end

  def delete_space(%Space{} = space) do
    with :ok <- can_delete_space?(space),
         {:ok, deleted_space} <- soft_delete_space(space) do
      Events.broadcast_updated(deleted_space.id)
      {:ok, deleted_space}
    end
  end

  def can_delete_space?(%Space{} = space) do
    case AccountDeletion.can_delete_space?(space) do
      :ok -> ensure_single_direct_membership(space)
      {:error, _reason} = error -> error
    end
  end

  defp maybe_broadcast_space_updated({:ok, _struct} = result, space_id)
       when is_binary(space_id) do
    Events.broadcast_updated(space_id)
    result
  end

  defp maybe_broadcast_space_updated(result, _space_id), do: result

  defp ensure_single_direct_membership(%Space{id: space_id}) do
    membership_count =
      from(membership in Membership,
        where: membership.space_id == ^space_id and not is_nil(membership.user_id)
      )
      |> Repo.aggregate(:count, :id)

    if membership_count == 1, do: :ok, else: {:error, "Memberships exist"}
  end

  defp soft_delete_space(%Space{} = space) do
    space
    |> Ecto.Changeset.change(%{deleted_at: DateTime.utc_now()})
    |> Repo.update()
  end

  defp peek_jwt_claims(jwt_string) do
    with [_header, payload, _signature] <- String.split(jwt_string, ".", parts: 3),
         {:ok, json} <- Base.url_decode64(payload, padding: false),
         {:ok, claims} <- Jason.decode(json),
         true <- is_map(claims) do
      {:ok, claims}
    else
      _error -> :error
    end
  end

  defp validate_jwt_time_claims(claims) when is_map(claims) do
    now = System.system_time(:second)

    with :ok <- validate_jwt_numeric_date(claims, "iat"),
         :ok <- validate_jwt_numeric_date(claims, "exp"),
         :ok <- validate_jwt_issued_at(Map.get(claims, "iat"), now),
         :ok <- validate_jwt_expires_at(Map.get(claims, "exp"), now) do
      validate_jwt_time_order(Map.get(claims, "iat"), Map.get(claims, "exp"))
    end
  end

  defp validate_jwt_numeric_date(claims, claim) do
    case Map.fetch(claims, claim) do
      :error -> :ok
      {:ok, value} when is_integer(value) -> :ok
      {:ok, _value} -> :error
    end
  end

  defp validate_jwt_issued_at(nil, _now), do: :ok

  defp validate_jwt_issued_at(issued_at, now)
       when issued_at <= now + @jwt_time_claim_leeway_seconds,
       do: :ok

  defp validate_jwt_issued_at(_issued_at, _now), do: :error

  defp validate_jwt_expires_at(nil, _now), do: :ok

  defp validate_jwt_expires_at(expires_at, now)
       when expires_at + @jwt_time_claim_leeway_seconds >= now,
       do: :ok

  defp validate_jwt_expires_at(_expires_at, _now), do: :error

  defp validate_jwt_time_order(issued_at, expires_at)
       when is_integer(issued_at) and is_integer(expires_at) and expires_at < issued_at,
       do: :error

  defp validate_jwt_time_order(_issued_at, _expires_at), do: :ok

  defp matching_jwt_space_and_key(sub, jwt_string) when is_binary(sub) do
    sub
    |> jwt_space_candidates()
    |> Enum.find_value(fn %Space{} = space ->
      case matching_jwt_key(space, jwt_string) do
        {:ok, %Key{} = key} -> {:ok, key, space}
        _error -> nil
      end
    end)
    |> case do
      {:ok, %Key{}, %Space{}} = result -> result
      _error -> :error
    end
  end

  defp matching_jwt_space_and_key(_sub, _jwt_string), do: :error

  defp jwt_space_candidates(sub) when is_binary(sub) do
    cond do
      byte_size(sub) == 15 ->
        sub |> binary_part(0, 5) |> list_spaces_by_hash()

      byte_size(sub) == 5 ->
        list_spaces_by_hash(sub)

      true ->
        case LegacyShortUUID.cast(sub) do
          {:ok, id} ->
            list_space_by_scope_id(id)

          :error ->
            []
        end
    end
  end

  defp jwt_space_candidates(_sub), do: []

  defp list_space_by_scope_id(id) do
    case list_space_by_id(id) do
      [] -> list_space_by_embed_id(id)
      spaces -> spaces
    end
  end

  defp list_spaces_by_hash(hash) when is_binary(hash) do
    normalized_space_hash = normalize_space_hash(hash)

    from(s in Space,
      where: s.hash == ^normalized_space_hash and is_nil(s.deleted_at)
    )
    |> Repo.all()
  end

  defp list_space_by_id(uuid) when is_binary(uuid) do
    case Repo.one(from(space in Space, where: space.id == ^uuid and is_nil(space.deleted_at))) do
      %Space{} = space -> [space]
      nil -> []
    end
  end

  defp list_space_by_embed_id(id) do
    from(s in Space,
      join: e in MaveCore.Embeds.Embed,
      on: e.space_id == s.id,
      where: e.id == ^id and is_nil(e.deleted_at) and is_nil(s.deleted_at),
      select: s
    )
    |> Repo.all()
  end

  defp matching_jwt_key(%Space{} = space, jwt_string) do
    space
    |> list_keys()
    |> Enum.find_value(fn %Key{} = key ->
      if jwt_signed_with_key?(jwt_string, key), do: {:ok, key}
    end)
    |> case do
      {:ok, %Key{}} = result -> result
      _error -> :error
    end
  end

  defp jwt_signed_with_key?(jwt_string, %Key{} = key) do
    with [header, payload, signature] <- String.split(jwt_string, ".", parts: 3),
         {:ok, decoded_signature} <- Base.url_decode64(signature, padding: false) do
      signing_input = "#{header}.#{payload}"

      expected_signature =
        :crypto.mac(:hmac, :sha256, display_api_key(key.key, key.secret), signing_input)

      byte_size(decoded_signature) == byte_size(expected_signature) and
        Plug.Crypto.secure_compare(decoded_signature, expected_signature)
    else
      _error -> false
    end
  end

  defp maybe_update_jwt_key_last_used(%Key{} = key, true), do: update_last_used(key)
  defp maybe_update_jwt_key_last_used(%Key{} = key, _mark_use), do: {:ok, key}

  defp sync_domain_cors(space_id) when is_binary(space_id) do
    space_id
    |> get_space_with_domains()
    |> sync_domain_cors_for_space()
  end

  defp sync_domain_cors_by_hash(space_hash, storage_profile) when is_binary(space_hash) do
    normalized_space_hash = normalize_space_hash(space_hash)

    normalized_space_hash
    |> get_space_with_domains_by_hash()
    |> maybe_shared_storage_space_for_bucket_sync(normalized_space_hash, storage_profile)
    |> sync_domain_cors_for_space()
  end

  defp get_space_with_domains(space_id) do
    from(s in Space,
      where: s.id == ^space_id and is_nil(s.deleted_at),
      preload: [:domains]
    )
    |> Repo.one()
  end

  defp get_space_with_domains_by_hash(space_hash) do
    from(s in Space,
      where: s.hash == ^space_hash and is_nil(s.deleted_at),
      preload: [:domains],
      limit: 2
    )
    |> Repo.all()
    |> unique_result()
  end

  defp normalize_space_hash(space_hash) when is_binary(space_hash), do: String.trim(space_hash)
  defp normalize_space_hash(space_hash), do: space_hash

  defp unique_result([result]), do: result
  defp unique_result(_results), do: nil

  defp storage_profile_for_hash(repo, space_hash) do
    if SharedStorageSpace.hash?(space_hash) do
      configured_shared_storage_profile(space_hash) ||
        shared_storage_profile_from_repo(repo, space_hash)
    else
      unique_storage_profile_from_repo(repo, space_hash)
    end
  end

  defp unique_storage_profile_from_repo(repo, space_hash) do
    query =
      from(s in "spaces",
        where: s.hash == ^space_hash and is_nil(s.deleted_at),
        select: s.region,
        limit: 2
      )

    case query |> repo.all() |> unique_result() do
      nil -> nil
      profile -> StorageProfiles.resolve(profile)
    end
  end

  defp shared_storage_profile_from_repo(repo, shared_hash) do
    from(s in "spaces",
      where: s.hash == ^shared_hash and is_nil(s.deleted_at),
      select: s.region
    )
    |> repo.all()
    |> shared_storage_profile_from_regions()
  end

  defp fallback_storage_profile(space_hash) do
    configured_shared_storage_profile(space_hash) || StorageProfiles.default()
  end

  defp configured_shared_storage_profile(space_hash) do
    with true <- SharedStorageSpace.hash?(space_hash),
         profile when not is_nil(profile) <-
           configured_shared_storage_profile_from_default_space() do
      StorageProfiles.resolve(profile)
    else
      _ -> nil
    end
  end

  defp configured_shared_storage_profile_from_default_space do
    case Application.get_env(:mave_core, :default_space_attrs, %{}) do
      %{} = attrs ->
        configured_hash = Map.get(attrs, "hash") || Map.get(attrs, :hash)

        if SharedStorageSpace.hash?(configured_hash) do
          Map.get(attrs, "region") || Map.get(attrs, :region)
        end

      _ ->
        nil
    end
  end

  defp maybe_shared_storage_space_for_bucket_sync(
         %Space{} = space,
         _space_hash,
         _storage_profile
       ),
       do: space

  defp maybe_shared_storage_space_for_bucket_sync(nil, space_hash, storage_profile) do
    if SharedStorageSpace.hash?(space_hash) do
      %Space{
        hash: SharedStorageSpace.hash(),
        region: shared_storage_profile(storage_profile),
        hotlink_protection_enabled: false,
        domains: []
      }
    end
  end

  defp shared_storage_profile(nil) do
    configured_shared_storage_profile(SharedStorageSpace.hash()) ||
      shared_storage_profile_from_spaces() ||
      StorageProfiles.default()
  end

  defp shared_storage_profile(storage_profile), do: StorageProfiles.resolve(storage_profile)

  defp shared_storage_profile_from_spaces do
    shared_hash = SharedStorageSpace.hash()

    from(s in Space,
      where: s.hash == ^shared_hash and is_nil(s.deleted_at),
      select: s.region
    )
    |> Repo.all()
    |> shared_storage_profile_from_regions()
  end

  defp shared_storage_profile_from_regions(regions) do
    regions
    |> Enum.reject(&is_nil/1)
    |> Enum.map(&StorageProfiles.resolve/1)
    |> Enum.uniq()
    |> case do
      [region] -> region
      _regions -> nil
    end
  end

  defp log_domain_cors_result(:ok, _space), do: :ok

  defp log_domain_cors_result({:error, reason}, %Space{hash: hash}) do
    Logger.warning("Failed to sync bucket CORS for space #{hash}: #{inspect(reason)}")
    :ok
  end

  defp do_process_webhook_delivery(%WebhookDelivery{} = delivery, max_attempts) do
    now = DateTime.utc_now() |> DateTime.truncate(:microsecond)

    if is_nil(delivery.webhook) or delivery.webhook.enabled != true do
      cancel_webhook_delivery(delivery, now)
      {:ok, :canceled}
    else
      process_active_webhook_delivery(delivery, now, max_attempts)
    end
  end

  defp create_membership_invite_transaction(
         space,
         created_by,
         normalized_email,
         invitee_user,
         role
       ) do
    Repo.transaction(fn ->
      case create_membership_invite_record(
             space,
             created_by,
             normalized_email,
             invitee_user,
             role
           ) do
        {:ok, membership} -> membership
        {:error, reason} -> Repo.rollback(reason)
      end
    end)
  end

  defp create_membership_invite_record(space, created_by, normalized_email, invitee_user, role) do
    invite_attrs = membership_invite_attrs(created_by, normalized_email, invitee_user)

    with {:ok, invite} <- insert_membership_invite(invite_attrs),
         {:ok, membership} <- insert_invited_membership(space, invite, role) do
      {:ok, Repo.preload(membership, invite: [:user])}
    end
  end

  defp membership_invite_attrs(created_by, normalized_email, invitee_user) do
    %{email: normalized_email, created_by_id: created_by.id}
    |> maybe_put_invited_user(invitee_user)
  end

  defp insert_membership_invite(invite_attrs) do
    %MembershipInvite{}
    |> MembershipInvite.create_changeset(invite_attrs)
    |> Repo.insert()
  end

  defp insert_invited_membership(space, invite, role) do
    %Membership{}
    |> Membership.create_changeset(%{space_id: space.id, invite_id: invite.id, role: role})
    |> Repo.insert()
  end

  defp accept_membership_invite_transaction(invite, membership, user) do
    Repo.transaction(fn ->
      case accept_membership_invite_record(invite, membership, user) do
        {:ok, accepted_membership} -> accepted_membership
        {:error, reason} -> Repo.rollback(reason)
      end
    end)
  end

  defp accept_membership_invite_record(invite, membership, user) do
    with {:ok, _invite} <- update_accepted_invite(invite),
         {:ok, membership} <- update_membership_invitee(membership, user) do
      {:ok, reload_membership(membership.id)}
    end
  end

  defp update_accepted_invite(invite) do
    invite
    |> MembershipInvite.accept_changeset()
    |> Repo.update()
  end

  defp update_membership_invitee(membership, user) do
    membership
    |> Membership.create_changeset(%{user_id: user.id})
    |> Repo.update()
  end

  defp reload_membership(membership_id) do
    Membership
    |> Repo.get!(membership_id)
    |> Repo.preload([:space, :user, invite: [:user]])
  end

  defp create_webhook_delivery(webhook, acc, space, normalized_event_type, payload, enqueue?) do
    webhook
    |> insert_webhook_delivery(space, normalized_event_type, payload)
    |> reduce_webhook_delivery(acc, webhook, enqueue?)
  end

  defp insert_webhook_delivery(webhook, space, normalized_event_type, payload) do
    attrs = %{
      "space_id" => space.id,
      "webhook_id" => webhook.id,
      "event_type" => normalized_event_type,
      "payload" => payload,
      "state" => :pending,
      "attempts" => 0
    }

    %WebhookDelivery{}
    |> WebhookDelivery.create_changeset(attrs)
    |> Repo.insert()
  end

  defp reduce_webhook_delivery({:ok, delivery}, acc, _webhook, enqueue?) do
    log_enqueue_delivery_result(delivery.id, maybe_enqueue_delivery_job(delivery.id, enqueue?))
    [delivery | acc]
  end

  defp reduce_webhook_delivery({:error, changeset}, acc, webhook, _enqueue?) do
    Logger.warning(
      "Failed to create webhook delivery for webhook #{webhook.id}: #{inspect(changeset.errors)}"
    )

    acc
  end

  defp log_enqueue_delivery_result(_delivery_id, :ok), do: :ok

  defp log_enqueue_delivery_result(delivery_id, {:error, reason}) do
    Logger.warning("Failed to enqueue webhook delivery #{delivery_id}: #{inspect(reason)}")
  end

  defp sync_domain_cors_for_space(nil), do: :ok

  defp sync_domain_cors_for_space(%Space{} = space) do
    space
    |> run_domain_cors_sync()
    |> log_domain_cors_result(space)
  end

  defp run_domain_cors_sync(space) do
    case bucket_cors_syncer() do
      fun when is_function(fun, 1) -> fun.(space)
      module when is_atom(module) -> module.sync_space_domain_cors(space)
    end
  end

  defp bucket_cors_syncer do
    Application.get_env(:mave_core, :bucket_cors_syncer, &Storage.sync_space_domain_cors/1)
  end

  defp cancel_webhook_delivery(delivery, now) do
    delivery
    |> WebhookDelivery.update_changeset(%{
      state: :canceled,
      failed_at: now,
      next_attempt_at: nil,
      error: "webhook missing or disabled"
    })
    |> Repo.update()
  end

  defp process_active_webhook_delivery(delivery, now, max_attempts) do
    attempt = delivery.attempts + 1

    case mark_webhook_delivery_processing(delivery, attempt) do
      {:ok, updated_delivery} ->
        handle_webhook_delivery_result(updated_delivery, attempt, now, max_attempts)

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp mark_webhook_delivery_processing(delivery, attempt) do
    delivery
    |> WebhookDelivery.update_changeset(%{
      state: :processing,
      attempts: attempt,
      next_attempt_at: nil
    })
    |> Repo.update()
  end

  defp handle_webhook_delivery_result(delivery, attempt, now, max_attempts) do
    event_payload = webhook_event_payload(delivery)

    case deliver_webhook(delivery.webhook, event_payload) do
      {:ok, response} ->
        mark_webhook_delivery_succeeded(delivery, response, now)
        {:ok, :succeeded}

      {:error, reason, response} ->
        handle_delivery_failure(delivery, attempt, now, reason, response, max_attempts)
    end
  end

  defp mark_webhook_delivery_succeeded(delivery, response, now) do
    delivery
    |> WebhookDelivery.update_changeset(%{
      state: :succeeded,
      delivered_at: now,
      failed_at: nil,
      next_attempt_at: nil,
      response_code: response.status,
      response_headers: response.headers,
      response_body: response.body,
      error: nil
    })
    |> Repo.update()
  end

  defp handle_delivery_failure(
         delivery,
         _attempt,
         now,
         {:unsafe_webhook_url, _reason} = reason,
         response,
         _max_attempts
       ) do
    mark_webhook_delivery_failed(delivery, now, reason, response)
    {:ok, :failed}
  end

  defp handle_delivery_failure(delivery, attempt, now, reason, response, max_attempts)
       when attempt < max_attempts do
    backoff = delivery_backoff_seconds(attempt)

    delivery
    |> WebhookDelivery.update_changeset(%{
      state: :pending,
      failed_at: nil,
      next_attempt_at: DateTime.add(now, backoff, :second),
      response_code: response && response.status,
      response_headers: response && response.headers,
      response_body: response && response.body,
      error: inspect(reason)
    })
    |> Repo.update()

    {:retry, backoff}
  end

  defp handle_delivery_failure(delivery, _attempt, now, reason, response, _max_attempts) do
    mark_webhook_delivery_failed(delivery, now, reason, response)
    {:ok, :failed}
  end

  defp mark_webhook_delivery_failed(delivery, now, reason, response) do
    delivery
    |> WebhookDelivery.update_changeset(%{
      state: :failed,
      failed_at: now,
      next_attempt_at: nil,
      response_code: response && response.status,
      response_headers: response && response.headers,
      response_body: response && response.body,
      error: inspect(reason)
    })
    |> Repo.update()
  end

  defp deliver_webhook(%Webhook{} = webhook, payload) do
    payload_json = Jason.encode!(payload)

    signature_time = DateTime.utc_now() |> DateTime.to_unix()

    signature =
      :crypto.mac(:hmac, :sha256, "#{signature_time}.#{webhook.secret}", payload_json)
      |> Base.encode16(case: :lower)

    headers = [
      {"Mave-Signature", "t=#{signature_time},v1=#{signature}"},
      {"Content-Type", "application/json"}
    ]

    with {:ok, req_options} <- webhook_req_options(webhook.url, payload_json, headers) do
      case Req.request(req_options) do
        {:ok, %Req.Response{} = response} when response.status in 200..299 ->
          {:ok, webhook_response_snapshot(response)}

        {:ok, %Req.Response{} = response} ->
          {:error, {:http_error, response.status}, webhook_response_snapshot(response)}

        {:error, reason} ->
          {:error, reason, nil}
      end
    end
  end

  defp webhook_req_options(webhook_url, payload_json, headers) do
    case PublicHttpUrl.req_options(webhook_url,
           method: :post,
           body: payload_json,
           headers: headers,
           decode_body: false,
           into: &collect_webhook_response_body/2,
           raw: true
         ) do
      {:ok, req_options} -> {:ok, req_options}
      {:error, reason} -> {:error, {:unsafe_webhook_url, reason}, nil}
    end
  end

  defp webhook_event_payload(%WebhookDelivery{} = delivery) do
    %{
      "id" => public_shortuuid(delivery.id),
      "type" => delivery.event_type |> Atom.to_string() |> String.replace("_", "."),
      "data" => delivery.payload || %{},
      "object" => "event",
      "created" => DateTime.to_unix(delivery.inserted_at)
    }
  end

  defp collect_webhook_response_body(
         {:data, data},
         {request, %Req.Response{} = response}
       )
       when is_binary(data) do
    capture_limit = @webhook_response_body_limit - byte_size(@webhook_response_body_truncated)
    body = if is_binary(response.body), do: response.body, else: ""
    available = max(capture_limit - byte_size(body), 0)

    if byte_size(data) <= available do
      {:cont, {request, %{response | body: body <> data}}}
    else
      prefix = if available > 0, do: binary_part(data, 0, available), else: ""

      response =
        response
        |> Map.put(:body, body <> prefix)
        |> Req.Response.put_private(:mave_core_webhook_body_truncated, true)

      {:halt, {request, response}}
    end
  end

  defp webhook_response_snapshot(%Req.Response{} = response) do
    body_truncated? =
      Req.Response.get_private(response, :mave_core_webhook_body_truncated, false)

    {headers, headers_truncated?} = response_headers_to_map(response)

    truncation =
      []
      |> maybe_add_truncation("body", body_truncated?)
      |> maybe_add_truncation("headers", headers_truncated?)

    headers =
      if truncation == [] do
        headers
      else
        Map.put(headers, @webhook_response_truncated_header, Enum.join(truncation, ","))
      end

    %{
      status: response.status,
      headers: headers,
      body: response_body(response.body, body_truncated?)
    }
  end

  defp response_headers_to_map(%Req.Response{} = response) do
    marker_size =
      byte_size(@webhook_response_truncated_header) + byte_size("body,headers")

    persisted_limit = @webhook_response_headers_limit - marker_size

    response
    |> Req.get_headers_list()
    |> Enum.reduce_while(
      {%{}, 0, 0, false},
      &reduce_response_header(&1, &2, persisted_limit)
    )
    |> then(fn {headers, _size, _count, truncated?} -> {headers, truncated?} end)
  end

  defp response_headers_to_map(_), do: {%{}, false}

  defp reduce_response_header(
         _header,
         {headers, size, count, _truncated?},
         _persisted_limit
       )
       when count >= @webhook_response_header_count_limit do
    {:halt, {headers, size, count, true}}
  end

  defp reduce_response_header(
         {key, value},
         {headers, size, count, truncated?},
         persisted_limit
       ) do
    {key, key_truncated?} = bounded_response_text(key, @webhook_response_header_name_limit)
    {value, value_truncated?} = bounded_response_text(value, @webhook_response_header_field_limit)
    key = String.downcase(key)
    separator_size = if Map.has_key?(headers, key), do: 2, else: 0
    field_size = byte_size(key) + byte_size(value) + separator_size

    if key == @webhook_response_truncated_header do
      {:cont, {headers, size, count + 1, true}}
    else
      maybe_store_response_header(
        {key, value},
        {headers, size, count, truncated? or key_truncated? or value_truncated?},
        field_size,
        persisted_limit
      )
    end
  end

  defp maybe_store_response_header(
         _header,
         {headers, size, count, _truncated?},
         field_size,
         persisted_limit
       )
       when size + field_size > persisted_limit do
    {:halt, {headers, size, count, true}}
  end

  defp maybe_store_response_header(
         {key, value},
         {headers, size, count, truncated?},
         field_size,
         _persisted_limit
       ) do
    updated_headers =
      Map.update(headers, key, value, fn existing -> existing <> ", " <> value end)

    if response_headers_fit?(updated_headers) do
      {:cont, {updated_headers, size + field_size, count + 1, truncated?}}
    else
      {:halt, {headers, size, count, true}}
    end
  end

  defp response_headers_fit?(headers) do
    headers
    |> Map.put(@webhook_response_truncated_header, "body,headers")
    |> Jason.encode!()
    |> byte_size()
    |> Kernel.<=(@webhook_response_headers_json_limit)
  end

  defp response_body(body, truncated?) when is_binary(body) do
    body = String.replace_invalid(body, "?")

    if truncated? do
      body <> @webhook_response_body_truncated
    else
      body
    end
  end

  defp response_body(body, truncated?) do
    case Jason.encode(body) do
      {:ok, encoded} -> response_body(encoded, truncated?)
      _ -> response_body(inspect(body), truncated?)
    end
  end

  defp bounded_response_text(value, limit) do
    value = to_string(value)
    truncated? = byte_size(value) > limit
    value = if truncated?, do: binary_part(value, 0, limit), else: value
    {String.replace_invalid(value, "?"), truncated?}
  end

  defp maybe_add_truncation(parts, part, true), do: [part | parts]
  defp maybe_add_truncation(parts, _part, false), do: parts

  defp get_delivery_with_webhook(delivery_id) do
    from(d in WebhookDelivery,
      where: d.id == ^delivery_id,
      preload: [:webhook]
    )
    |> Repo.one()
  end

  defp maybe_enqueue_delivery_job(_delivery_id, false), do: :ok

  defp maybe_enqueue_delivery_job(delivery_id, true) do
    %{"delivery_id" => delivery_id}
    |> WebhookDeliveryWorker.new()
    |> Oban.insert()
    |> case do
      {:ok, _job} -> :ok
      {:error, reason} -> {:error, reason}
    end
  rescue
    error in RuntimeError ->
      Logger.warning(
        "Oban unavailable for webhook delivery #{delivery_id}: #{Exception.message(error)}"
      )

      :ok
  end

  defp get_embed_by_space_and_embed_hashes(space_hash, embed_hash)
       when is_binary(space_hash) and is_binary(embed_hash) do
    normalized_space_hash = normalize_space_hash(space_hash)

    from(e in Embed,
      join: s in assoc(e, :space),
      where: s.hash == ^normalized_space_hash and is_nil(s.deleted_at),
      where: e.hash == ^embed_hash and is_nil(e.deleted_at),
      preload: [space: s]
    )
    |> Repo.one()
  end

  defp ensure_webhook_space(%Space{hash: hash} = space, _embed) when is_binary(hash), do: space

  defp ensure_webhook_space(%Space{id: id}, _embed) when is_binary(id) do
    Repo.get!(Space, id)
  end

  defp webhook_embed_payload(%Space{} = space, %Embed{type: :video} = embed, event_type) do
    embed = PublicApi.get_embed_by_hash(space, embed.hash) || embed

    space
    |> PublicApi.webhook_video_response(embed)
    |> maybe_nil_created_poster_image(event_type)
  end

  defp webhook_embed_payload(%Space{} = space, %Embed{type: :collection} = embed, _event_type) do
    embed = PublicApi.get_embed_by_hash(space, embed.hash) || embed
    PublicApi.collection_response(space, embed)
  end

  defp maybe_nil_created_poster_image(payload, event_type) do
    case normalize_event_type(event_type) do
      {:ok, :video_created} -> Map.put(payload, :poster_image, nil)
      _ -> payload
    end
  end

  defp public_shortuuid(id) when is_binary(id) do
    case LegacyShortUUID.encode(id) do
      {:ok, shortuuid} -> shortuuid
      {:error, _reason} -> id
    end
  end

  defp public_shortuuid(id), do: id

  defp normalize_event_type(event_type) when is_binary(event_type) do
    event_type
    |> String.trim()
    |> String.downcase()
    |> String.replace(".", "_")
    |> String.to_existing_atom()
    |> normalize_event_type()
  rescue
    ArgumentError -> {:error, :invalid_event_type}
  end

  defp normalize_event_type(event_type) when is_atom(event_type) do
    if event_type in Webhook.mave_events() do
      {:ok, event_type}
    else
      {:error, :invalid_event_type}
    end
  end

  defp normalize_event_type(_), do: {:error, :invalid_event_type}

  defp delivery_backoff_seconds(attempt) do
    attempt
    |> max(1)
    |> then(&round(:math.pow(2, &1)))
    |> min(300)
  end

  defp stringify_keys(map) do
    Map.new(map, fn {key, value} -> {to_string(key), value} end)
  end

  defp generated_key_attrs(attrs, space_id) do
    Map.merge(attrs, %{
      "space_id" => space_id,
      "key" => LegacyShortUUID.generate(),
      "secret" => LegacyShortUUID.generate()
    })
  end

  defp get_internal_key(%Space{id: space_id}, purpose) do
    Repo.get_by(Key, space_id: space_id, purpose: purpose)
  end

  defp normalize_key_description(%{"description" => description} = attrs)
       when is_binary(description) do
    case String.trim(description) do
      "" -> Map.put(attrs, "description", nil)
      trimmed -> Map.put(attrs, "description", trimmed)
    end
  end

  defp normalize_key_description(attrs), do: attrs

  defp validate_member_email(""), do: {:error, :invalid_email}

  defp validate_member_email(email) do
    if String.contains?(email, "@"), do: {:ok, email}, else: {:error, :invalid_email}
  end

  defp ensure_can_add_member(%Space{} = space, role) do
    UsageLimits.can_add_space_member?(space, role)
  end

  defp maybe_put_invited_user(attrs, %User{} = user), do: Map.put(attrs, :user_id, user.id)
  defp maybe_put_invited_user(attrs, _user), do: attrs

  defp get_active_user_by_email(email) when is_binary(email) do
    from(u in User,
      where: u.email == ^email and is_nil(u.deleted_at)
    )
    |> Repo.one()
  end

  defp membership_exists?(_space_id, nil), do: false

  defp membership_exists?(space_id, user_id) when is_binary(space_id) and is_binary(user_id) do
    from(m in Membership,
      where: m.space_id == ^space_id and m.user_id == ^user_id
    )
    |> Repo.exists?()
  end

  defp pending_membership_exists?(space_id, email, invitee_user)
       when is_binary(space_id) and is_binary(email) do
    invitee_user_id = invitee_user && invitee_user.id

    base_query =
      from(m in Membership,
        join: i in assoc(m, :invite),
        where: m.space_id == ^space_id and is_nil(i.accepted_at),
        where: i.email == ^email
      )

    query =
      if is_binary(invitee_user_id) do
        from([m, i] in base_query, or_where: i.user_id == ^invitee_user_id)
      else
        base_query
      end

    Repo.exists?(query)
  end

  defp can_accept_invite?(%MembershipInvite{user_id: user_id}, %User{id: current_user_id})
       when is_binary(user_id) do
    user_id == current_user_id
  end

  defp can_accept_invite?(%MembershipInvite{email: email}, %User{email: current_email})
       when is_binary(email) and is_binary(current_email) do
    String.downcase(email) == String.downcase(current_email)
  end

  defp can_accept_invite?(_, _), do: false
end
