defmodule MaveCore.Accounts do
  @moduledoc """
  Accounts context for magic-link authentication.
  """

  import Ecto.Query, warn: false

  alias MaveCore.AccountDeletion
  alias MaveCore.Accounts.{User, UserNotifier, UserToken}
  alias MaveCore.Embeds
  alias MaveCore.Repo
  alias MaveCore.Spaces
  alias MaveCore.Spaces.{Domain, Membership, MembershipInvite, Space}
  alias MaveCore.StorageProfiles

  @space_hash_chars ~c"0123456789abcdefghijklmnopqrstuvwxyz"
  @space_hash_length 5
  @public_registration_lock "mave:public-registration"
  @default_public_registration_max_users 100

  def change_login_user(attrs \\ %{}) do
    %User{}
    |> User.login_changeset(attrs)
  end

  def change_registration_user(attrs \\ %{}) do
    %User{}
    |> User.registration_changeset(attrs)
  end

  def get_user_by_email(email) when is_binary(email) do
    User
    |> where([u], is_nil(u.deleted_at))
    |> Repo.get_by(email: email)
    |> preload_user_space()
  end

  def get_user_by_google_uid(google_uid) when is_binary(google_uid) do
    User
    |> where([u], is_nil(u.deleted_at))
    |> Repo.get_by(google_uid: google_uid)
    |> preload_user_space()
  end

  def get_user_by_session_token(token) do
    {:ok, query} = UserToken.verify_session_token_query(token)

    case Repo.one(query) do
      %{user: user} ->
        case resolve_login_space(user) do
          {:ok, user} -> user
          {:error, _reason} -> nil
        end

      _ ->
        nil
    end
  end

  def can_create_new_login_token(email, minutes \\ 2) do
    can_create_email_token(email, "login", minutes)
  end

  def can_create_new_invite_token(email, minutes \\ 2) do
    can_create_email_token(email, "invite", minutes)
  end

  defp can_create_email_token(email, context, minutes)
       when is_binary(email) and is_binary(context) do
    query =
      from(t in UserToken,
        where:
          t.sent_to == ^email and t.context == ^context and
            t.inserted_at > ago(^minutes, "minute") and is_nil(t.invalidated_at)
      )

    not Repo.exists?(query)
  end

  def create_user(email, attrs \\ %{}) when is_binary(email) and is_map(attrs) do
    skip_email_validation? = map_get(attrs, :skip_email_validation, false)

    registration_attrs =
      attrs
      |> Map.drop([:skip_email_validation, "skip_email_validation"])
      |> Map.put(:email, email)
      |> Map.put_new(:confirmed_at, DateTime.utc_now())

    Repo.transaction(fn ->
      with {:ok, user} <-
             register_user(registration_attrs, skip_email_validation: skip_email_validation?),
           {:ok, space} <- create_space(default_space_attrs()),
           {:ok, membership} <- create_membership(user, space, "owner"),
           {:ok, updated_user} <- set_current_space_membership(user, membership) do
        Repo.preload(updated_user, current_space_membership: [space: [:domains]])
      else
        {:error, reason} -> Repo.rollback(reason)
      end
    end)
    |> case do
      {:ok, user} -> {:ok, user}
      {:error, reason} -> {:error, reason}
    end
  end

  def public_registration_enabled? do
    config = public_registration_config()
    config.enabled == true and is_integer(config.max_users) and config.max_users > 0
  end

  def register_public_user(email, signup_url_fun)
      when is_binary(email) and is_function(signup_url_fun, 1) do
    Repo.transaction(fn ->
      with :ok <- lock_public_registration(),
           :ok <- ensure_public_registration_available(),
           nil <- get_user_by_email(email),
           {:ok, user} <- register_user(%{email: email, confirmed_at: nil}, []),
           {:ok, token} <- insert_email_token(user, "login"),
           {:ok, _metadata} <-
             UserNotifier.deliver_signup_instructions(user, signup_url_fun.(token)) do
        preload_user_space(user)
      else
        %User{} -> Repo.rollback(:already_registered)
        {:error, reason} -> Repo.rollback(reason)
        other -> Repo.rollback(other)
      end
    end)
    |> case do
      {:ok, user} -> {:ok, user}
      {:error, reason} -> {:error, reason}
    end
  end

  def create_invited_user(email, attrs \\ %{}) when is_binary(email) and is_map(attrs) do
    registration_attrs =
      attrs
      |> Map.drop([:skip_email_validation, "skip_email_validation"])
      |> Map.put(:email, email)
      |> Map.put_new(:confirmed_at, nil)

    %User{}
    |> User.registration_changeset(registration_attrs)
    |> Repo.insert()
    |> case do
      {:ok, user} ->
        {:ok, preload_user_space(user)}

      {:error, changeset} = error ->
        handle_invited_user_insert_error(changeset, error, email)
    end
  end

  def delete_account_and_space(%User{} = user, %Space{} = space) do
    Repo.transaction(fn -> delete_account_and_space_records(user, space) end)
  end

  defp delete_account_and_space_records(%User{} = user, %Space{} = space) do
    with {:ok, current_space} <- lock_active_space(space.id),
         :ok <- can_delete_account_and_space?(user, current_space),
         {:ok, _deleted_embeds} <- Embeds.delete_space_videos(current_space),
         {:ok, _space} <- Spaces.delete_space(current_space),
         {:ok, deleted_user} <- delete(user),
         :ok <- AccountDeletion.enqueue_deleted_space_cleanup(current_space) do
      deleted_user
    else
      {:error, reason} -> Repo.rollback(reason)
    end
  end

  defp lock_active_space(space_id) do
    Space
    |> where([space], space.id == ^space_id and is_nil(space.deleted_at))
    |> lock("FOR UPDATE")
    |> Repo.one()
    |> case do
      %Space{} = space -> {:ok, space}
      nil -> {:error, :space_not_found}
    end
  end

  def can_delete_account_and_space?(%User{} = user, %Space{} = space) do
    case ensure_single_direct_membership(user, space) do
      :ok -> Spaces.can_delete_space?(space)
      {:error, _reason} = error -> error
    end
  end

  def delete(%User{} = user) do
    Repo.transaction(fn ->
      with :ok <- ensure_single_direct_membership(user),
           {:ok, deleted_user} <- anonymize_and_delete_user(user) do
        deleted_user
      else
        {:error, reason} -> Repo.rollback(reason)
      end
    end)
  end

  def login_or_register_with_google(attrs) when is_map(attrs) do
    uid = map_get(attrs, :uid)
    email = map_get(attrs, :email)
    email_verified? = map_get(attrs, :email_verified, false) in [true, "true", 1, "1"]

    cond do
      not email_verified? ->
        {:error, :email_unverified}

      not valid_google_value?(uid) ->
        {:error, :invalid_uid}

      not valid_google_value?(email) ->
        {:error, :invalid_email}

      true ->
        email = String.trim(email)

        uid
        |> login_or_register_google_user(email)
        |> case do
          {:ok, user} -> {:ok, user}
          {:error, reason} -> {:error, reason}
        end
    end
  end

  def ensure_default_space(%User{} = user) do
    case current_or_first_membership(user) do
      {membership, space} ->
        with {:ok, updated_user} <- maybe_set_current_space_membership(user, membership) do
          {:ok, %{updated_user | current_space_membership: %{membership | space: space}}}
        end

      nil ->
        with {:ok, space} <- create_space(default_space_attrs()),
             {:ok, membership} <- create_membership(user, space, "owner"),
             {:ok, updated_user} <- set_current_space_membership(user, membership) do
          {:ok, Repo.preload(updated_user, current_space_membership: [space: [:domains]])}
        end
    end
  end

  def list_user_spaces(%User{id: user_id}) do
    accessible_space_ids = accessible_space_ids_query(user_id)
    domains_query = from(d in Domain, order_by: [asc: d.inserted_at])

    from(s in Space,
      where: s.id in subquery(accessible_space_ids) and is_nil(s.deleted_at),
      order_by: [asc: s.inserted_at],
      preload: [domains: ^domains_query]
    )
    |> Repo.all()
    |> Enum.sort_by(&first_space_domain_for_sort/1)
  end

  def can_access_space?(%User{id: user_id}, %Space{id: space_id}) do
    accessible_ids = accessible_space_ids_query(user_id)

    Repo.exists?(
      from(s in Space,
        where: s.id == ^space_id and s.id in subquery(accessible_ids) and is_nil(s.deleted_at)
      )
    )
  end

  def can_access_space?(_user, _space), do: false

  def create_space_for_user(%User{} = user, attrs \\ %{}) when is_map(attrs) do
    Repo.transaction(fn ->
      with {:ok, space} <- create_space(attrs),
           {:ok, _domain} <- maybe_create_domain(space, attrs),
           {:ok, membership} <- create_membership(user, space, "owner"),
           {:ok, updated_user} <- set_current_space_membership(user, membership) do
        Repo.preload(updated_user, current_space_membership: [space: [:domains]])
      else
        {:error, reason} -> Repo.rollback(reason)
      end
    end)
    |> case do
      {:ok, user} -> {:ok, user}
      {:error, reason} -> {:error, reason}
    end
  end

  def get_membership(%User{id: user_id}, %Space{id: space_id}) do
    case Repo.one(
           from(m in Membership,
             where: m.user_id == ^user_id and m.space_id == ^space_id,
             limit: 1
           )
         ) do
      %Membership{} = membership ->
        membership

      nil ->
        direct_space_ids = direct_space_ids(user_id)

        from(m in Membership,
          where: m.space_id == ^space_id and m.owner_space_id in ^direct_space_ids,
          limit: 1
        )
        |> Repo.one()
    end
  end

  def set_current_space_membership(%User{} = user, %Membership{} = membership) do
    user
    |> User.current_space_membership_changeset(membership.id)
    |> Repo.update()
  end

  def maybe_set_current_space_membership(%User{} = user, %Membership{} = membership) do
    if user.current_space_membership_id == membership.id do
      {:ok, user}
    else
      set_current_space_membership(user, membership)
    end
  end

  def mark_google_link_pending(%User{} = user, pending_since \\ DateTime.utc_now()) do
    user
    |> User.google_uid_pending_changeset(pending_since)
    |> Repo.update()
    |> case do
      {:ok, user} -> {:ok, preload_user_space(user)}
      other -> other
    end
  end

  def unlink_google(%User{} = user) do
    user
    |> User.unlink_google_changeset()
    |> Repo.update()
    |> case do
      {:ok, user} -> {:ok, preload_user_space(user)}
      other -> other
    end
  end

  def link_google_account(%User{} = user, attrs) when is_map(attrs) do
    uid = map_get(attrs, :uid)
    email = map_get(attrs, :email)
    now = map_get(attrs, :now, DateTime.utc_now())

    with :ok <- validate_google_link(user, uid, email, now),
         {:ok, linked_user} <- persist_google_link(user, uid) do
      {:ok, preload_user_space(linked_user)}
    else
      {:error, reason} -> {:error, reason}
      other -> other
    end
  end

  def generate_user_login_token(%User{} = user) do
    {token, user_token} = UserToken.build_email_token(user, "login")
    Repo.insert!(user_token)
    token
  end

  def generate_user_invite_token(%User{} = user) do
    {token, user_token} = UserToken.build_email_token(user, "invite")
    Repo.insert!(user_token)
    token
  end

  def deliver_user_login_instructions(%User{} = user, login_url_fun)
      when is_function(login_url_fun, 1) do
    encoded_token = generate_user_login_token(user)
    UserNotifier.deliver_login_instructions(user, login_url_fun.(encoded_token))
  end

  def deliver_user_signup_instructions(%User{} = user, signup_url_fun)
      when is_function(signup_url_fun, 1) do
    encoded_token = generate_user_login_token(user)
    UserNotifier.deliver_signup_instructions(user, signup_url_fun.(encoded_token))
  end

  def login_user(token), do: login_user(token, "login")

  def login_user(token, contexts) when is_list(contexts) do
    Enum.find_value(contexts, {:error, "couldn't login to account"}, fn context ->
      case login_user(token, context) do
        {:ok, _result} = success -> success
        _ -> false
      end
    end)
  end

  def login_user(token, context) when is_binary(context) do
    with {:ok, query} <- UserToken.verify_email_token_query(token, context),
         %{user: %User{} = user} = login_token <- Repo.one(query),
         :ok <- confirm_user(user),
         {:ok, updated_login_token} <- mark_email_token_used(login_token, context),
         {:ok, user} <- resolve_login_space(user) do
      {:ok, {user, updated_login_token}}
    else
      _ -> {:error, "couldn't login to account"}
    end
  end

  def generate_user_session_token(login_token, user) do
    {token, user_token} = UserToken.build_session_token(login_token, user)
    Repo.insert!(user_token)
    token
  end

  def deliver_space_invite_instructions(%User{} = user, %Space{} = space, invite_url_fun)
      when is_function(invite_url_fun, 1) do
    deliver_space_invite_instructions(user, space, nil, invite_url_fun)
  end

  def deliver_space_invite_instructions(
        %User{} = user,
        %Space{} = space,
        inviter,
        invite_url_fun
      )
      when is_function(invite_url_fun, 1) do
    encoded_token = generate_user_invite_token(user)

    UserNotifier.deliver_space_invite_instructions(
      user,
      space,
      inviter,
      invite_url_fun.(encoded_token)
    )
  end

  def set_current_space_by_hash(%User{} = user, space_hash) when is_binary(space_hash) do
    user_id = user.id

    with %Membership{} = membership <- accessible_membership_by_space_hash(user_id, space_hash),
         {:ok, updated_user} <- set_current_space_membership(user, membership) do
      {:ok, Repo.preload(updated_user, current_space_membership: [space: [:domains]])}
    else
      nil -> {:error, :not_found}
      {:error, _reason} = error -> error
    end
  end

  def set_current_space_by_id(%User{} = user, space_id) when is_binary(space_id) do
    with %Space{} = space <-
           from(s in Space, where: s.id == ^space_id and is_nil(s.deleted_at))
           |> Repo.one(),
         %Membership{} = membership <- get_membership(user, space),
         {:ok, updated_user} <- set_current_space_membership(user, membership) do
      {:ok, Repo.preload(updated_user, current_space_membership: [space: [:domains]])}
    else
      nil -> {:error, :not_found}
      {:error, _reason} = error -> error
    end
  end

  def delete_session_token(token) do
    session_token = UserToken.token_and_context_query(token, "session") |> Repo.one()

    if session_token do
      login_token = UserToken.login_token_query(session_token.login_token_id) |> Repo.one()

      if login_token do
        login_token
        |> Ecto.Changeset.change(%{invalidated_at: DateTime.utc_now()})
        |> Repo.update!()

        Repo.delete_all(UserToken.session_token_with_login(login_token))
      end

      Repo.delete_all(UserToken.token_and_context_query(token, "session"))
    end

    :ok
  end

  def invalidate_login_token_for_session(token) when is_binary(token) do
    session_token = UserToken.token_and_context_query(token, "session") |> Repo.one()

    if session_token do
      login_token = UserToken.login_token_query(session_token.login_token_id) |> Repo.one()

      if login_token do
        login_token
        |> Ecto.Changeset.change(%{invalidated_at: DateTime.utc_now()})
        |> Repo.update!()
      end
    end

    :ok
  end

  defp register_user(attrs, opts) do
    %User{}
    |> User.registration_changeset(attrs, opts)
    |> Repo.insert()
  end

  defp ensure_single_direct_membership(%User{id: user_id}) do
    case direct_memberships_for_user(user_id) do
      [%Membership{role: role}] when role in ["owner", :owner] -> :ok
      _other -> {:error, "Part of other space"}
    end
  end

  defp ensure_single_direct_membership(%User{id: user_id}, %Space{id: space_id}) do
    case direct_memberships_for_user(user_id) do
      [%Membership{space_id: ^space_id, role: role}] when role in ["owner", :owner] -> :ok
      _other -> {:error, "Part of other space"}
    end
  end

  defp direct_memberships_for_user(user_id) do
    Membership
    |> where([membership], membership.user_id == ^user_id)
    |> Repo.all()
  end

  defp anonymize_and_delete_user(%User{} = user) do
    anonymized_email = "deleted##{user.id}"

    UserToken
    |> where([token], token.user_id == ^user.id)
    |> Repo.update_all(set: [sent_to: anonymized_email])

    MembershipInvite
    |> where([invite], invite.email == ^user.email)
    |> Repo.update_all(set: [email: anonymized_email])

    user
    |> Ecto.Changeset.change(%{
      current_space_membership_id: nil,
      deleted_at: DateTime.utc_now(),
      email: anonymized_email,
      google_uid: nil,
      google_uid_pending_since: nil
    })
    |> Repo.update()
  end

  defp confirm_user(user) do
    if is_nil(user.confirmed_at) do
      user
      |> User.confirm_changeset()
      |> Repo.update()
      |> case do
        {:ok, _updated} -> :ok
        {:error, reason} -> {:error, reason}
      end
    else
      :ok
    end
  end

  defp mark_email_token_used(token, _context), do: set_attempt_for_token(token)

  defp set_attempt_for_token(token) do
    token
    |> Ecto.Changeset.change(%{attempts: token.attempts + 1, last_attempt_at: DateTime.utc_now()})
    |> Repo.update()
  end

  def owner_space_options_for_user(_user), do: []

  defp default_space_attrs do
    case Application.get_env(:mave_core, :default_space_attrs, %{}) do
      attrs when is_map(attrs) -> attrs
      _ -> %{}
    end
  end

  defp create_space(attrs) when is_map(attrs) do
    attrs =
      attrs
      |> Map.drop([:domain, "domain", :owner_space_id, "owner_space_id"])
      |> stringify_keys()
      |> Map.put_new("hash", generate_space_hash())
      |> Map.put_new("region", StorageProfiles.default())
      |> Map.put_new("public_sharing_enabled", false)
      |> Map.put_new("hotlink_protection_enabled", false)

    %Space{}
    |> Space.create_changeset(attrs)
    |> Repo.insert()
    |> case do
      {:ok, space} ->
        {:ok, space}

      {:error, changeset} ->
        {:error, changeset}
    end
  end

  defp create_membership(%User{} = user, %Space{} = space, role) do
    %Membership{}
    |> Membership.create_changeset(%{user_id: user.id, space_id: space.id, role: role})
    |> Repo.insert()
  end

  defp duplicate_user_email?(changeset) do
    Enum.any?(changeset.errors, fn
      {:email, {"Already registered?", _}} -> true
      {:email, {"has already been taken", _}} -> true
      _ -> false
    end)
  end

  defp handle_invited_user_insert_error(changeset, error, email) do
    if duplicate_user_email?(changeset) do
      fetch_existing_invited_user(email, error)
    else
      error
    end
  end

  defp fetch_existing_invited_user(email, error) do
    case get_user_by_email(email) do
      %User{} = user -> {:ok, user}
      nil -> error
    end
  end

  defp get_or_create_google_user(uid, email) do
    case get_user_by_google_uid(uid) do
      %User{} = user ->
        {:ok, user}

      nil ->
        case get_user_by_email(email) do
          nil ->
            register_public_google_user(uid, email)

          %User{google_uid: nil} = user ->
            user
            |> User.google_uid_changeset(uid)
            |> Repo.update()

          %User{google_uid: ^uid} = user ->
            {:ok, user}

          %User{} ->
            {:error, :no_match}
        end
    end
  end

  defp login_or_register_google_user(uid, email) do
    Repo.transaction(fn ->
      case get_or_create_google_user_with_space(uid, email) do
        {:ok, user} -> user
        {:error, reason} -> Repo.rollback(reason)
      end
    end)
  end

  defp register_public_google_user(uid, email) do
    with :ok <- lock_public_registration(),
         :ok <- ensure_public_registration_available() do
      create_user(email, %{google_uid: uid, skip_email_validation: true})
    end
  end

  defp insert_email_token(%User{} = user, context) when is_binary(context) do
    {token, user_token} = UserToken.build_email_token(user, context)

    case Repo.insert(user_token) do
      {:ok, _user_token} -> {:ok, token}
      {:error, reason} -> {:error, reason}
    end
  end

  defp lock_public_registration do
    case Repo.query("SELECT pg_advisory_xact_lock(hashtext($1))", [@public_registration_lock]) do
      {:ok, _result} -> :ok
      {:error, reason} -> {:error, reason}
    end
  end

  defp ensure_public_registration_available do
    config = public_registration_config()

    cond do
      config.enabled != true ->
        {:error, :public_registration_disabled}

      not is_integer(config.max_users) or config.max_users <= 0 ->
        {:error, :public_registration_disabled}

      total_user_count() >= config.max_users ->
        {:error, :public_registration_limit_reached}

      true ->
        :ok
    end
  end

  defp total_user_count, do: Repo.aggregate(User, :count, :id)

  defp public_registration_config do
    config = Application.get_env(:mave_core, :public_registration, [])

    %{
      enabled: registration_config_value(config, :enabled, false),
      max_users:
        registration_config_value(config, :max_users, @default_public_registration_max_users)
    }
  end

  defp registration_config_value(config, key, default) when is_list(config),
    do: Keyword.get(config, key, default)

  defp registration_config_value(config, key, default) when is_map(config),
    do: Map.get(config, key, Map.get(config, Atom.to_string(key), default))

  defp registration_config_value(_config, _key, default), do: default

  defp get_or_create_google_user_with_space(uid, email) do
    with {:ok, user} <- get_or_create_google_user(uid, email) do
      ensure_default_space(user)
    end
  end

  defp valid_google_value?(value), do: is_binary(value) and String.trim(value) != ""

  defp validate_google_link(user, uid, email, now) do
    with :ok <- validate_google_uid(uid),
         :ok <- validate_google_email(email),
         :ok <- validate_google_link_state(user, now),
         :ok <- validate_google_email_match(user, email) do
      validate_google_uid_availability(user, uid)
    end
  end

  defp validate_google_uid(uid) do
    if valid_google_value?(uid), do: :ok, else: {:error, :invalid_uid}
  end

  defp validate_google_email(email) do
    if valid_google_value?(email), do: :ok, else: {:error, :invalid_email}
  end

  defp validate_google_link_state(user, now) do
    cond do
      not is_nil(user.google_uid) ->
        {:error, :already_linked}

      is_nil(user.google_uid_pending_since) ->
        {:error, :google_link_not_pending}

      google_link_expired?(user, now) ->
        {:error, :google_link_expired}

      true ->
        :ok
    end
  end

  defp google_link_expired?(user, now) do
    DateTime.diff(now, user.google_uid_pending_since, :second) > 120
  end

  defp validate_google_email_match(user, email) do
    if String.trim(user.email || "") == String.trim(email) do
      :ok
    else
      {:error, :google_email_mismatch}
    end
  end

  defp validate_google_uid_availability(user, uid) do
    if google_uid_taken?(user, uid), do: {:error, :google_uid_taken}, else: :ok
  end

  defp google_uid_taken?(user, uid) do
    match?(%User{id: existing_id} when existing_id != user.id, get_user_by_google_uid(uid))
  end

  defp persist_google_link(user, uid) do
    user
    |> User.google_uid_changeset(String.trim(uid))
    |> Repo.update()
  end

  # A selected space is a preference, not authority. Recheck direct and inherited
  # membership before exposing it through either a login link or an existing session.
  defp resolve_login_space(%User{} = user) do
    case current_or_first_membership(user) do
      {membership, space} ->
        with {:ok, updated_user} <- maybe_set_current_space_membership(user, membership) do
          {:ok, %{updated_user | current_space_membership: %{membership | space: space}}}
        end

      nil ->
        with {:ok, updated_user} <-
               user |> User.current_space_membership_changeset(nil) |> Repo.update() do
          {:ok, %{updated_user | current_space_membership: nil}}
        end
    end
  end

  defp current_or_first_membership(%User{} = user) do
    with current_space_membership_id when is_binary(current_space_membership_id) <-
           user.current_space_membership_id,
         {membership, space} <- fetch_membership_with_space(user.id, current_space_membership_id) do
      {membership, space}
    else
      _ -> first_membership_with_space(user.id)
    end
  end

  defp fetch_membership_with_space(user_id, membership_id) do
    accessible_membership_query(user_id)
    |> where([m], m.id == ^membership_id)
    |> join(:inner, [m], s in assoc(m, :space))
    |> where([_m, s], is_nil(s.deleted_at))
    |> preload([_m, s], space: {s, [:domains]})
    |> select([m, s], {m, s})
    |> limit(1)
    |> Repo.one()
  end

  defp first_membership_with_space(user_id) do
    accessible_membership_query(user_id)
    |> join(:inner, [m], s in assoc(m, :space))
    |> where([_m, s], is_nil(s.deleted_at))
    |> order_by(
      [m, _s],
      asc:
        fragment(
          "CASE WHEN ? = ? THEN 0 ELSE 1 END",
          m.user_id,
          type(^user_id, MaveCore.Ecto.LegacyShortUUID)
        ),
      asc: m.inserted_at
    )
    |> preload([_m, s], space: {s, [:domains]})
    |> select([m, s], {m, s})
    |> limit(1)
    |> Repo.one()
  end

  defp accessible_membership_query(user_id) do
    direct_space_ids = direct_space_ids(user_id)

    from(m in Membership,
      where: m.user_id == ^user_id or m.owner_space_id in ^direct_space_ids
    )
  end

  defp accessible_membership_by_space_hash(user_id, space_hash) do
    user_id
    |> accessible_membership_query()
    |> join(:inner, [m], s in assoc(m, :space))
    |> where([_m, s], s.hash == ^space_hash and is_nil(s.deleted_at))
    |> preload([_m, s], space: {s, [:domains]})
    |> limit(2)
    |> Repo.all()
    |> case do
      [membership] -> membership
      _other -> nil
    end
  end

  defp accessible_space_ids_query(user_id) do
    accessible_membership_query(user_id)
    |> distinct([m], m.space_id)
    |> select([m], m.space_id)
  end

  defp direct_space_ids(user_id) do
    from(m in Membership,
      where: m.user_id == ^user_id,
      join: s in assoc(m, :space),
      where: is_nil(s.deleted_at),
      select: m.space_id
    )
    |> Repo.all()
  end

  defp maybe_create_domain(%Space{} = space, attrs) when is_map(attrs) do
    case map_get(attrs, :domain) do
      domain when is_binary(domain) and domain != "" ->
        Spaces.create_domain(space, %{domain: domain})

      _ ->
        {:ok, nil}
    end
  end

  defp first_space_domain_for_sort(%Space{domains: domains}) when is_list(domains) do
    case List.first(domains) do
      %Domain{domain: domain} when is_binary(domain) -> domain
      _ -> ""
    end
  end

  defp first_space_domain_for_sort(_space), do: ""

  defp stringify_keys(map) when is_map(map) do
    Enum.into(map, %{}, fn
      {key, value} when is_atom(key) -> {Atom.to_string(key), value}
      pair -> pair
    end)
  end

  defp generate_space_hash do
    candidate = for _ <- 1..@space_hash_length, into: "", do: <<Enum.random(@space_hash_chars)>>

    exists? =
      Space
      |> where([space], space.hash == ^candidate)
      |> Repo.exists?()

    if exists?, do: generate_space_hash(), else: candidate
  end

  defp map_get(map, key, default \\ nil) when is_map(map) do
    Map.get(map, key, Map.get(map, to_string(key), default))
  end

  defp preload_user_space(nil), do: nil

  defp preload_user_space(%User{} = user),
    do: Repo.preload(user, current_space_membership: [space: [:domains]])
end
