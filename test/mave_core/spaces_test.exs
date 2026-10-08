defmodule MaveCore.SpacesTest do
  use MaveCore.DataCase, async: false

  alias MaveCore.{Accounts, Repo, Spaces}
  alias MaveCore.Spaces.{Domain, Key, MembershipInvite, Space, Webhook}
  alias MaveCore.Uploads.Token

  setup do
    original_syncer = Application.get_env(:mave_core, :bucket_cors_syncer)
    test_pid = self()

    Application.put_env(:mave_core, :bucket_cors_syncer, fn space ->
      send(test_pid, {:bucket_cors_synced, space})
      :ok
    end)

    on_exit(fn ->
      if is_nil(original_syncer) do
        Application.delete_env(:mave_core, :bucket_cors_syncer)
      else
        Application.put_env(:mave_core, :bucket_cors_syncer, original_syncer)
      end
    end)

    email = "spaces-#{System.unique_integer([:positive])}@example.com"
    {:ok, user} = Accounts.create_user(email)
    space = user.current_space_membership.space
    %{space: space, user: user}
  end

  test "domain CRUD normalizes and validates domain values", %{space: space} do
    assert [] == Spaces.list_domains(space)

    assert {:ok, %Domain{} = domain} =
             Spaces.create_domain(space, %{"domain" => "https://WWW.Example.com/path"})

    assert domain.domain == "example.com"
    assert_receive {:bucket_cors_synced, %{id: space_id, domains: [%{domain: "example.com"}]}}
    assert space_id == space.id

    domain_id = domain.id
    assert [%Domain{id: ^domain_id}] = Spaces.list_domains(space)
    assert %Domain{} = Spaces.get_domain_for_space(space, domain.id)

    assert {:error, invalid_changeset} = Spaces.create_domain(space, %{"domain" => "invalid"})
    assert "This doesn't seem like a valid domain" in errors_on(invalid_changeset).domain

    assert {:error, duplicate_changeset} =
             Spaces.create_domain(space, %{"domain" => "example.com"})

    assert "has already been taken" in errors_on(duplicate_changeset).domain

    assert {:ok, _deleted} = Spaces.delete_domain(domain)
    assert_receive {:bucket_cors_synced, %{id: space_id, domains: []}}
    assert space_id == space.id
    assert [] == Spaces.list_domains(space)
  end

  test "key CRUD and display encoding are legacy-compatible", %{space: space} do
    assert [] == Spaces.list_keys(space)

    assert {:ok, %Key{} = key} = Spaces.create_key(space, %{description: "  Production  "})
    assert String.length(key.key) == 22
    assert String.length(key.secret) == 22
    assert key.description == "Production"
    assert key.access_level == :read_write
    assert is_nil(key.purpose)
    assert Spaces.key_can_write?(key)

    display = Spaces.display_api_key(key.key, key.secret)
    assert Base.decode64!(display) == "#{key.key}:#{key.secret}"

    key_id = key.id
    assert [%Key{id: ^key_id}] = Spaces.list_keys(space)
    assert %Key{} = Spaces.get_key_for_space(space, key.id)

    assert {:ok, updated_key} =
             Spaces.update_key(key, %{
               description: "Website uploader",
               access_level: "read_only"
             })

    assert updated_key.description == "Website uploader"
    assert updated_key.access_level == :read_only

    assert {:error, invalid_changeset} =
             Spaces.update_key(updated_key, %{description: String.duplicate("x", 161)})

    assert "should be at most 160 character(s)" in errors_on(invalid_changeset).description

    assert {:ok, undescribed_key} =
             Spaces.update_key(updated_key, %{description: "   ", access_level: "read_write"})

    assert is_nil(undescribed_key.description)
    assert undescribed_key.access_level == :read_write

    assert {:ok, _deleted} = Spaces.delete_key(undescribed_key)
    assert [] == Spaces.list_keys(space)
  end

  test "changing key access is immediate and internal keys stay separate", %{
    space: space
  } do
    assert {:ok, %Key{} = key} = Spaces.create_key(space)
    token = signed_api_jwt(key, %{"sub" => space.id})

    assert {:ok, %{key: %Key{access_level: :read_write}}} =
             Spaces.validate_api_jwt(token, false)

    assert {:ok, %Key{access_level: :read_only} = read_only_key} =
             Spaces.make_key_read_only(key)

    refute Spaces.key_can_write?(read_only_key)

    assert {:ok, %{key: %Key{access_level: :read_only}}} =
             Spaces.validate_api_jwt(token, false)

    assert {:ok,
            %Key{
              id: internal_key_id,
              access_level: :read_write,
              purpose: :dashboard_uploads
            } = internal_key} =
             Spaces.ensure_internal_key(space, :dashboard_uploads)

    refute internal_key_id == key.id
    assert internal_key.description == "Dashboard uploads"
    assert [^internal_key] = Spaces.list_keys(space) -- [read_only_key]
    assert [^read_only_key] = Spaces.list_user_managed_keys(space)
    assert is_nil(Spaces.get_user_managed_key_for_space(space, internal_key.id))

    assert {:ok, %Key{id: ^internal_key_id}} =
             Spaces.ensure_internal_key(space, :dashboard_uploads)

    assert {:ok, %Key{purpose: nil} = customer_write_key} =
             Spaces.ensure_key(space, %{description: "Public integration"})

    refute customer_write_key.id == internal_key_id

    assert {:ok, %Key{access_level: :read_write} = read_write_key} =
             Spaces.set_key_access_level(read_only_key, :read_write)

    assert Spaces.key_can_write?(read_write_key)

    assert {:ok, %{key: %Key{access_level: :read_write}}} =
             Spaces.validate_api_jwt(token, false)

    assert {:error, invalid_changeset} =
             Spaces.set_key_access_level(read_write_key, "invalid")

    assert "is invalid" in errors_on(invalid_changeset).access_level
  end

  test "validate_api_jwt keeps time claims optional", %{space: space} do
    {:ok, %Key{} = key} = Spaces.create_key(space)
    token = signed_api_jwt(key, %{"sub" => space.id})

    assert {:ok, %{claims: %{"sub" => sub}, key: %Key{id: key_id}}} =
             Spaces.validate_api_jwt(token, false)

    assert sub == space.id
    assert key_id == key.id
  end

  test "validate_api_jwt rejects tokens for a deleted space", %{space: space} do
    {:ok, %Key{} = key} = Spaces.create_key(space)
    token = signed_api_jwt(key, %{"sub" => space.id})

    assert {:ok, _claims} = Spaces.validate_api_jwt(token, false)
    assert {:ok, _deleted_space} = Spaces.delete_space(space)
    assert {:error, _reason} = Spaces.validate_api_jwt(token, false)
  end

  test "validate_api_jwt rejects invalid provided time claims", %{space: space} do
    {:ok, %Key{} = key} = Spaces.create_key(space)
    now = System.system_time(:second)

    expired_token = Token.sign_api_key(key, space.id, now: now - 3_600, max_age: 30)
    future_token = Token.sign_api_key(key, space.id, now: now + 3_600)

    malformed_iat_token = signed_api_jwt(key, %{"sub" => space.id, "iat" => "not-a-date"})
    malformed_exp_token = signed_api_jwt(key, %{"sub" => space.id, "exp" => "not-a-date"})

    backwards_token =
      signed_api_jwt(key, %{"sub" => space.id, "iat" => now, "exp" => now - 1})

    assert {:error, _reason} = Spaces.validate_api_jwt(expired_token, false)
    assert {:error, _reason} = Spaces.validate_api_jwt(future_token, false)
    assert {:error, _reason} = Spaces.validate_api_jwt(malformed_iat_token, false)
    assert {:error, _reason} = Spaces.validate_api_jwt(malformed_exp_token, false)
    assert {:error, _reason} = Spaces.validate_api_jwt(backwards_token, false)
  end

  test "webhook CRUD and HTTPS validation", %{space: space} do
    assert {:ok, %Webhook{} = webhook} =
             Spaces.create_webhook(space, %{
               "url" => "https://example.com/webhook",
               "description" => "Primary webhook"
             })

    assert webhook.enabled
    assert webhook.secret =~ "whsec_"
    assert Enum.sort(webhook.enabled_events) == Enum.sort(Webhook.mave_events())
    webhook_id = webhook.id
    assert [%Webhook{id: ^webhook_id}] = Spaces.list_webhooks(space)
    assert %Webhook{} = Spaces.get_webhook_for_space(space, webhook.id)

    assert {:ok, %Webhook{} = disabled_webhook} = Spaces.toggle_webhook(webhook)
    refute disabled_webhook.enabled

    assert {:ok, %Webhook{} = enabled_webhook} =
             Spaces.update_webhook(disabled_webhook, %{"enabled" => true})

    assert enabled_webhook.enabled

    assert {:error, changeset} =
             Spaces.create_webhook(space, %{"url" => "http://example.com/webhook"})

    assert "We need https to make it work" in errors_on(changeset).url

    assert {:ok, _deleted} = Spaces.delete_webhook(enabled_webhook)
    assert [] == Spaces.list_webhooks(space)
  end

  test "space feature updates persist", %{space: space} do
    assert {:ok, %Space{} = updated_space} =
             Spaces.update_space_features(space, %{
               public_sharing_enabled: true,
               hotlink_protection_enabled: true
             })

    refute updated_space.public_sharing_enabled
    assert updated_space.hotlink_protection_enabled

    assert_receive {:bucket_cors_synced,
                    %{id: space_id, hotlink_protection_enabled: true, domains: []}}

    assert space_id == space.id
  end

  test "space feature updates preserve imported public sharing state", %{space: space} do
    imported_space =
      space
      |> Ecto.Changeset.change(public_sharing_enabled: true)
      |> Repo.update!()

    assert {:ok, %Space{} = updated_space} =
             Spaces.update_space_features(imported_space, %{
               public_sharing_enabled: false,
               hotlink_protection_enabled: true
             })

    assert updated_space.public_sharing_enabled
    assert updated_space.hotlink_protection_enabled
  end

  test "shared-storage spaces cannot enable hotlink protection", %{space: space} do
    trial_space = force_space_hash!(space, "trial")

    assert {:error, changeset} =
             Spaces.update_space_features(trial_space, %{hotlink_protection_enabled: true})

    assert "cannot be enabled for shared-storage spaces" in errors_on(changeset).hotlink_protection_enabled
    refute Repo.get!(Space, trial_space.id).hotlink_protection_enabled
    refute_receive {:bucket_cors_synced, _space}, 50
  end

  test "space processing updates persist", %{space: space} do
    assert {:ok, %Space{} = updated_space} =
             Spaces.update_space_processing(space, %{
               default_flow_template: "publish_local"
             })

    assert updated_space.default_flow_template == "publish_local"

    assert {:ok, %Space{} = cleared_space} =
             Spaces.update_space_processing(updated_space, %{
               default_flow_template: ""
             })

    assert is_nil(cleared_space.default_flow_template)
  end

  test "space hash lookup returns nil instead of raising when trial hashes are duplicated", %{
    space: first_space
  } do
    force_space_hash!(first_space, "trial")

    email = "spaces-trial-#{System.unique_integer([:positive])}@example.com"
    {:ok, user} = Accounts.create_user(email)
    _second_space = force_space_hash!(user.current_space_membership.space, "trial")

    assert is_nil(Spaces.get_space_by_hash("trial"))
  end

  test "storage profile lookup uses configured trial profile when trial hashes are duplicated", %{
    space: first_space
  } do
    original_repo = Application.get_env(:mave_core, :spaces_repo)
    original_default_space_attrs = Application.get_env(:mave_core, :default_space_attrs)

    Application.put_env(:mave_core, :spaces_repo, Repo)

    Application.put_env(:mave_core, :default_space_attrs, %{"hash" => "trial", "region" => "eu_3"})

    on_exit(fn ->
      if is_nil(original_repo) do
        Application.delete_env(:mave_core, :spaces_repo)
      else
        Application.put_env(:mave_core, :spaces_repo, original_repo)
      end

      if is_nil(original_default_space_attrs) do
        Application.delete_env(:mave_core, :default_space_attrs)
      else
        Application.put_env(:mave_core, :default_space_attrs, original_default_space_attrs)
      end
    end)

    first_space |> Ecto.Changeset.change(%{hash: "trial", region: "eu"}) |> Repo.update!()

    email = "spaces-storage-trial-#{System.unique_integer([:positive])}@example.com"
    {:ok, user} = Accounts.create_user(email)

    user.current_space_membership.space
    |> Ecto.Changeset.change(%{hash: "trial", region: "eu"})
    |> Repo.update!()

    assert Spaces.get_storage_profile("trial") == "eu_3"
  end

  test "bucket access sync by hash keeps duplicated trial spaces public", %{space: first_space} do
    first_space |> Ecto.Changeset.change(%{hash: "trial", region: "eu"}) |> Repo.update!()

    email = "spaces-sync-trial-#{System.unique_integer([:positive])}@example.com"
    {:ok, user} = Accounts.create_user(email)

    user.current_space_membership.space
    |> Ecto.Changeset.change(%{hash: "trial", region: "eu"})
    |> Repo.update!()

    assert :ok = Spaces.sync_bucket_access_for_space_hash("trial", "eu_3")

    assert_receive {:bucket_cors_synced,
                    %{
                      hash: "trial",
                      region: "eu_3",
                      hotlink_protection_enabled: false,
                      domains: []
                    }}
  end

  test "team membership add/remove works without invites", %{space: space} do
    email = "team-member-#{System.unique_integer([:positive])}@example.com"
    {:ok, member_user} = Accounts.create_user(email)

    assert {:ok, membership} = Spaces.add_member_by_email(space, member_user.email)
    assert membership.role == "member"
    assert membership.user.email == member_user.email

    assert {:error, :already_member} = Spaces.add_member_by_email(space, member_user.email)

    memberships = Spaces.list_memberships(space)
    assert Enum.any?(memberships, &(&1.id == membership.id))

    owner_membership = Enum.find(memberships, &(&1.role in ["owner", :owner]))
    assert {:error, :cannot_remove_owner} = Spaces.remove_member(space, owner_membership.id, %{})

    assert {:ok, _} =
             Spaces.remove_member(space, membership.id, %{current_user_id: member_user.id})

    refute Spaces.get_membership_for_space(space, membership.id)
  end

  test "membership invite stays pending until accepted", %{space: space, user: owner} do
    email = "pending-member-#{System.unique_integer([:positive])}@example.com"
    {:ok, invitee} = Accounts.create_user(email)

    assert {:ok, membership} = Spaces.create_membership_invite(space, owner, invitee.email)
    assert is_nil(membership.user_id)
    assert %MembershipInvite{} = membership.invite
    assert membership.invite.user_id == invitee.id
    assert is_nil(membership.invite.accepted_at)

    refute Accounts.get_membership(invitee, space)

    assert {:ok, accepted_membership} = Spaces.accept_membership_invite(membership, invitee)
    assert accepted_membership.user_id == invitee.id
    assert accepted_membership.invite.accepted_at
    assert %{} = Accounts.get_membership(invitee, space)
  end

  defp signed_api_jwt(%Key{} = key, claims) when is_map(claims) do
    encoded_header = encode_jwt_segment(%{"alg" => "HS256", "typ" => "JWT"})
    encoded_claims = encode_jwt_segment(claims)
    signing_input = "#{encoded_header}.#{encoded_claims}"
    secret = Spaces.display_api_key(key.key, key.secret)

    signature =
      :crypto.mac(:hmac, :sha256, secret, signing_input)
      |> Base.url_encode64(padding: false)

    "#{signing_input}.#{signature}"
  end

  defp encode_jwt_segment(value) do
    value
    |> Jason.encode!()
    |> Base.url_encode64(padding: false)
  end

  defp force_space_hash!(space, hash) do
    space
    |> Ecto.Changeset.change(%{hash: hash})
    |> Repo.update!()
  end
end
