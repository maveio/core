defmodule MaveCore.AccountsTest do
  use MaveCore.DataCase, async: true

  alias MaveCore.Accounts
  alias MaveCore.Accounts.{User, UserToken}
  alias MaveCore.Embeds
  alias MaveCore.Embeds.Embed
  alias MaveCore.Repo
  alias MaveCore.Spaces
  alias MaveCore.Spaces.{Domain, Membership, MembershipInvite, Space}

  test "login and existing sessions recover from a deleted selected space" do
    {:ok, user} = Accounts.create_user("deleted-selection@example.com")
    fallback_id = user.current_space_membership_id
    {:ok, selected_user} = Accounts.create_space_for_user(user)
    deleted_space = selected_user.current_space_membership.space
    token = Accounts.generate_user_login_token(selected_user)
    {:ok, {selected_user, login_token}} = Accounts.login_user(token)
    session = Accounts.generate_user_session_token(login_token, selected_user)
    deleted_space |> Ecto.Changeset.change(deleted_at: DateTime.utc_now()) |> Repo.update!()

    assert session_user = Accounts.get_user_by_session_token(session)
    assert session_user.current_space_membership_id == fallback_id
    assert session_user.current_space_membership.id == fallback_id

    # Reproduce the stale selection independently for the magic-link path.
    Accounts.set_current_space_membership(selected_user, selected_user.current_space_membership)
    assert {:ok, {logged_in_user, _token}} = Accounts.login_user(token)
    assert logged_in_user.current_space_membership_id == fallback_id
    assert logged_in_user.current_space_membership.space.deleted_at == nil
    assert Repo.get!(User, user.id).current_space_membership_id == fallback_id
    refute Accounts.can_access_space?(logged_in_user, deleted_space)
  end

  test "login never trusts a selected membership belonging to another user" do
    {:ok, user} = Accounts.create_user("stale-selection@example.com")
    {:ok, stranger} = Accounts.create_user("other-selection@example.com")
    token = Accounts.generate_user_login_token(user)
    {:ok, {user, login_token}} = Accounts.login_user(token)
    session = Accounts.generate_user_session_token(login_token, user)

    for mode <- [:login, :session] do
      {:ok, _} = Accounts.set_current_space_membership(user, stranger.current_space_membership)

      recovered =
        case mode do
          :login ->
            assert {:ok, {recovered, _}} = Accounts.login_user(token)
            recovered

          :session ->
            Accounts.get_user_by_session_token(session)
        end

      assert recovered.current_space_membership_id == user.current_space_membership_id
      refute Accounts.can_access_space?(recovered, stranger.current_space_membership.space)
    end
  end

  test "login without any remaining space clears the selection without granting access" do
    {:ok, user} = Accounts.create_user("no-space-selection@example.com")
    space = user.current_space_membership.space
    token = Accounts.generate_user_login_token(user)
    space |> Ecto.Changeset.change(deleted_at: DateTime.utc_now()) |> Repo.update!()
    count_before = Repo.aggregate(Space, :count)

    assert {:ok, {recovered, _}} = Accounts.login_user(token)
    assert recovered.current_space_membership_id == nil
    assert recovered.current_space_membership == nil
    assert Repo.aggregate(Space, :count) == count_before
    refute Accounts.can_access_space?(recovered, space)
  end

  test "signup/login/session token flow works" do
    email = "core-auth-test@example.com"

    assert {:ok, user} = Accounts.create_user(email)
    assert user.email == email
    assert user.current_space_membership_id
    assert %{} = user.current_space_membership
    assert %{} = user.current_space_membership.space
    assert user.current_space_membership.space.hash =~ ~r/^[0-9a-z]{5}$/

    login_token = Accounts.generate_user_login_token(user)

    assert {:ok, {logged_in_user, persisted_login_token}} = Accounts.login_user(login_token)
    assert logged_in_user.id == user.id
    assert persisted_login_token.context == "login"
    assert persisted_login_token.attempts == 1
    refute persisted_login_token.invalidated_at

    assert {:ok, {reused_user, reused_login_token}} = Accounts.login_user(login_token)
    assert reused_user.id == user.id
    assert reused_login_token.id == persisted_login_token.id
    assert reused_login_token.attempts == 2
    refute reused_login_token.invalidated_at

    session_token = Accounts.generate_user_session_token(reused_login_token, reused_user)
    assert %{} = session_user = Accounts.get_user_by_session_token(session_token)
    assert session_user.id == user.id

    assert :ok = Accounts.delete_session_token(session_token)
    assert is_nil(Accounts.get_user_by_session_token(session_token))
    assert {:error, "couldn't login to account"} = Accounts.login_user(login_token)
  end

  test "user can create an additional space and it becomes current" do
    email = "core-extra-space-#{System.unique_integer([:positive])}@example.com"

    assert {:ok, user} = Accounts.create_user(email)
    original_space_id = user.current_space_membership.space.id

    assert {:ok, updated_user} = Accounts.create_space_for_user(user)

    new_space = updated_user.current_space_membership.space
    assert new_space.id != original_space_id
    assert new_space.hash =~ ~r/^[0-9a-z]{5}$/

    spaces = Accounts.list_user_spaces(updated_user)
    assert length(spaces) == 2
  end

  test "user spaces are sorted by first domain for the space picker" do
    email = "core-space-sort-#{System.unique_integer([:positive])}@example.com"

    assert {:ok, user} = Accounts.create_user(email)
    create_domain!(user.current_space_membership.space, "zeta.example.com")

    assert {:ok, user} = Accounts.create_space_for_user(user)
    create_domain!(user.current_space_membership.space, "beta.example.com")

    assert {:ok, user} = Accounts.create_space_for_user(user)
    create_domain!(user.current_space_membership.space, "alpha.example.com")

    assert {:ok, user} = Accounts.create_space_for_user(user)

    labels =
      user
      |> Accounts.list_user_spaces()
      |> Enum.map(&first_domain_label/1)

    assert labels == ["", "alpha.example.com", "beta.example.com", "zeta.example.com"]
  end

  test "user can switch current space by id" do
    email = "core-switch-space-#{System.unique_integer([:positive])}@example.com"

    assert {:ok, user} = Accounts.create_user(email)
    original_space_id = user.current_space_membership.space.id
    assert {:ok, updated_user} = Accounts.create_space_for_user(user)
    new_space = updated_user.current_space_membership.space

    assert {:ok, switched_user} =
             Accounts.set_current_space_by_id(updated_user, original_space_id)

    assert switched_user.current_space_membership.space.id == original_space_id
    refute switched_user.current_space_membership.space.id == new_space.id
  end

  test "user cannot switch current space to another user's space" do
    email = "core-switch-other-space-#{System.unique_integer([:positive])}@example.com"
    other_email = "core-switch-other-owner-#{System.unique_integer([:positive])}@example.com"

    assert {:ok, user} = Accounts.create_user(email)
    assert {:ok, other_user} = Accounts.create_user(other_email)
    original_membership_id = user.current_space_membership_id

    assert {:error, :not_found} =
             Accounts.set_current_space_by_id(user, other_user.current_space_membership.space.id)

    assert Repo.get!(User, user.id).current_space_membership_id == original_membership_id
  end

  test "delete_account_and_space soft-deletes the space and anonymizes the user" do
    email = "delete-account-#{System.unique_integer([:positive])}@example.com"

    assert {:ok, user} = Accounts.create_user(email)
    space = user.current_space_membership.space
    _login_token = Accounts.generate_user_login_token(user)
    video = video_embed_fixture(space)
    archived_video = video_embed_fixture(space, %{archived: true})

    invite =
      %MembershipInvite{}
      |> MembershipInvite.create_changeset(%{email: email, created_by_id: user.id})
      |> Repo.insert!()

    assert {:ok, deleted_user} = Accounts.delete_account_and_space(user, space)

    anonymized_email = "deleted##{user.id}"
    assert deleted_user.email == anonymized_email
    assert deleted_user.deleted_at
    assert is_nil(deleted_user.current_space_membership_id)
    assert Repo.get!(User, user.id).email == anonymized_email
    assert Repo.get!(Space, space.id).deleted_at
    assert Repo.get!(Embed, video.id).deleted_at
    assert Repo.get!(Embed, archived_video.id).deleted_at
    refute Accounts.get_user_by_email(email)

    assert [%UserToken{sent_to: ^anonymized_email}] =
             Repo.all(from(token in UserToken, where: token.user_id == ^user.id))

    assert Repo.get!(MembershipInvite, invite.id).email == anonymized_email
  end

  test "deleting an account in shared trial storage only soft-deletes its own videos" do
    assert {:ok, user} =
             Accounts.create_user(
               "delete-trial-account-#{System.unique_integer([:positive])}@example.com"
             )

    assert {:ok, other_user} =
             Accounts.create_user(
               "keep-trial-account-#{System.unique_integer([:positive])}@example.com"
             )

    space = force_space_hash!(user.current_space_membership.space, "trial")
    other_space = force_space_hash!(other_user.current_space_membership.space, "trial")
    video = video_embed_fixture(space)
    other_video = video_embed_fixture(other_space)

    assert {:ok, _deleted_user} = Accounts.delete_account_and_space(user, space)

    assert Repo.get!(Embed, video.id).deleted_at
    refute Repo.get!(Embed, other_video.id).deleted_at
    refute Repo.get!(Space, other_space.id).deleted_at
    assert {:error, :space_deleted} = Embeds.create_video_embed(space)
  end

  test "delete_account_and_space is atomic when the user belongs to another space" do
    email = "delete-account-extra-space-#{System.unique_integer([:positive])}@example.com"

    assert {:ok, user} = Accounts.create_user(email)
    first_space = user.current_space_membership.space
    assert {:ok, _updated_user} = Accounts.create_space_for_user(user)

    assert {:error, "Part of other space"} = Accounts.delete_account_and_space(user, first_space)

    assert is_nil(Repo.get!(User, user.id).deleted_at)
    assert is_nil(Repo.get!(Space, first_space.id).deleted_at)
    assert Accounts.get_user_by_email(email)
  end

  test "can_delete_account_and_space? reports when the user belongs to another space" do
    email = "delete-account-check-extra-space-#{System.unique_integer([:positive])}@example.com"

    assert {:ok, user} = Accounts.create_user(email)
    first_space = user.current_space_membership.space

    assert :ok = Accounts.can_delete_account_and_space?(user, first_space)

    assert {:ok, _updated_user} = Accounts.create_space_for_user(user)

    assert {:error, "Part of other space"} =
             Accounts.can_delete_account_and_space?(user, first_space)

    assert is_nil(Repo.get!(User, user.id).deleted_at)
    assert is_nil(Repo.get!(Space, first_space.id).deleted_at)
  end

  test "can_delete_account_and_space? reports when other members exist" do
    owner_email = "delete-account-check-owner-#{System.unique_integer([:positive])}@example.com"
    member_email = "delete-account-check-member-#{System.unique_integer([:positive])}@example.com"

    assert {:ok, owner} = Accounts.create_user(owner_email)
    assert {:ok, member} = Accounts.create_user(member_email)
    space = owner.current_space_membership.space

    assert {:ok, _membership} = Spaces.add_member_by_email(space, member.email)

    assert {:error, "Memberships exist"} =
             Accounts.can_delete_account_and_space?(owner, space)

    assert is_nil(Repo.get!(User, owner.id).deleted_at)
    assert is_nil(Repo.get!(Space, space.id).deleted_at)
  end

  test "delete_account_and_space refuses indirectly managed child spaces" do
    owner_email = "delete-account-owner-#{System.unique_integer([:positive])}@example.com"
    member_email = "delete-account-child-member-#{System.unique_integer([:positive])}@example.com"

    assert {:ok, owner_user} = Accounts.create_user(owner_email)
    assert {:ok, member_user} = Accounts.create_user(member_email)
    owner_space = owner_user.current_space_membership.space

    child_space =
      %Space{}
      |> Space.create_changeset(%{
        "hash" => "child#{System.unique_integer([:positive])}",
        "region" => "eu"
      })
      |> Repo.insert!()

    %Membership{}
    |> Membership.create_changeset(%{
      owner_space_id: owner_space.id,
      space_id: child_space.id,
      role: "owner"
    })
    |> Repo.insert!()

    assert {:ok, _member_membership} = Spaces.add_member_by_email(child_space, member_user.email)

    assert {:error, "Part of other space"} =
             Accounts.delete_account_and_space(owner_user, child_space)

    assert is_nil(Repo.get!(User, owner_user.id).deleted_at)
    assert is_nil(Repo.get!(Space, child_space.id).deleted_at)
    assert Accounts.get_user_by_email(owner_email)
  end

  test "user can switch current space by duplicate trial hash through their membership" do
    email = "core-switch-trial-space-#{System.unique_integer([:positive])}@example.com"

    other_email =
      "core-switch-other-trial-space-#{System.unique_integer([:positive])}@example.com"

    assert {:ok, user} = Accounts.create_user(email)
    assert {:ok, other_user} = Accounts.create_user(other_email)

    user_space = force_space_hash!(user.current_space_membership.space, "trial")
    _other_space = force_space_hash!(other_user.current_space_membership.space, "trial")

    assert {:ok, switched_user} = Accounts.set_current_space_by_hash(user, "trial")
    assert switched_user.current_space_membership.space.id == user_space.id
  end

  test "managed child spaces are accessible through owner space memberships" do
    email = "managed-child-access-#{System.unique_integer([:positive])}@example.com"
    assert {:ok, user} = Accounts.create_user(email)
    owner_space = user.current_space_membership.space

    child_space =
      %Space{}
      |> Space.create_changeset(%{
        "hash" => "child#{System.unique_integer([:positive])}",
        "region" => "eu"
      })
      |> Repo.insert!()

    %Membership{}
    |> Membership.create_changeset(%{
      owner_space_id: owner_space.id,
      space_id: child_space.id,
      role: "owner"
    })
    |> Repo.insert!()

    assert Enum.any?(Accounts.list_user_spaces(user), &(&1.id == child_space.id))

    assert {:ok, switched_user} = Accounts.set_current_space_by_id(user, child_space.id)
    assert switched_user.current_space_membership.space.id == child_space.id
    assert switched_user.current_space_membership.owner_space_id == owner_space.id
  end

  test "removing a user from the owner space also removes managed child access" do
    owner_email = "managed-owner-#{System.unique_integer([:positive])}@example.com"
    member_email = "managed-member-#{System.unique_integer([:positive])}@example.com"

    assert {:ok, owner_user} = Accounts.create_user(owner_email)
    assert {:ok, member_user} = Accounts.create_user(member_email)

    owner_space = owner_user.current_space_membership.space
    assert {:ok, owner_membership} = Spaces.add_member_by_email(owner_space, member_user.email)

    child_space =
      %Space{}
      |> Space.create_changeset(%{
        "hash" => "child#{System.unique_integer([:positive])}",
        "region" => "eu"
      })
      |> Repo.insert!()

    %Membership{}
    |> Membership.create_changeset(%{
      owner_space_id: owner_space.id,
      space_id: child_space.id,
      role: "owner"
    })
    |> Repo.insert!()

    assert Enum.any?(Accounts.list_user_spaces(member_user), &(&1.id == child_space.id))
    assert {:ok, _switched_user} = Accounts.set_current_space_by_id(member_user, child_space.id)

    login_token = Accounts.generate_user_login_token(member_user)
    assert {:ok, {selected_user, persisted_token}} = Accounts.login_user(login_token)
    assert selected_user.current_space_membership.space.id == child_space.id
    session_token = Accounts.generate_user_session_token(persisted_token, selected_user)

    assert {:ok, _deleted_membership} =
             Spaces.remove_member(owner_space, owner_membership.id, %{
               current_user_id: owner_user.id
             })

    refute Enum.any?(Accounts.list_user_spaces(member_user), &(&1.id == child_space.id))
    assert {:error, :not_found} = Accounts.set_current_space_by_id(member_user, child_space.id)

    assert session_user = Accounts.get_user_by_session_token(session_token)
    assert session_user.current_space_membership_id == member_user.current_space_membership_id
    assert {:ok, {login_user, _}} = Accounts.login_user(login_token)
    assert login_user.current_space_membership_id == member_user.current_space_membership_id
    refute Accounts.can_access_space?(login_user, child_space)

    assert {:ok, recovered_user} = Accounts.ensure_default_space(member_user)
    assert recovered_user.current_space_membership_id
    assert recovered_user.current_space_membership.space.id != owner_space.id
  end

  test "logout invalidates login token for throttling checks" do
    email = "core-auth-throttle-test@example.com"
    assert {:ok, user} = Accounts.create_user(email)

    login_token = Accounts.generate_user_login_token(user)
    assert {:ok, {logged_in_user, persisted_login_token}} = Accounts.login_user(login_token)

    session_token = Accounts.generate_user_session_token(persisted_login_token, logged_in_user)
    assert :ok = Accounts.delete_session_token(session_token)

    assert Accounts.can_create_new_login_token(email)
  end

  test "login token remains valid within the 15 minute validity window" do
    email = "core-auth-valid-token-test@example.com"
    assert {:ok, user} = Accounts.create_user(email)

    login_token = Accounts.generate_user_login_token(user)
    valid_at = DateTime.add(DateTime.utc_now(), -14 * 60, :second)

    Repo.get_by!(UserToken, user_id: user.id, context: "login")
    |> Ecto.Changeset.change(%{inserted_at: valid_at})
    |> Repo.update!()

    assert {:ok, {_logged_in_user, persisted_login_token}} = Accounts.login_user(login_token)
    refute persisted_login_token.invalidated_at
  end

  test "login token expires after the 15 minute validity window" do
    email = "core-auth-expired-token-test@example.com"
    assert {:ok, user} = Accounts.create_user(email)

    login_token = Accounts.generate_user_login_token(user)
    expired_at = DateTime.add(DateTime.utc_now(), -16 * 60, :second)

    Repo.get_by!(UserToken, user_id: user.id, context: "login")
    |> Ecto.Changeset.change(%{inserted_at: expired_at})
    |> Repo.update!()

    assert {:error, "couldn't login to account"} = Accounts.login_user(login_token)
  end

  test "google login uses existing user by google uid" do
    email = "google-existing-uid@example.com"
    uid = "google-uid-existing"

    assert {:ok, user} =
             Accounts.create_user(email, %{google_uid: uid, skip_email_validation: true})

    assert {:ok, logged_in_user} =
             Accounts.login_or_register_with_google(%{
               uid: uid,
               email: email,
               email_verified: true
             })

    assert logged_in_user.id == user.id
    assert logged_in_user.google_uid == uid
  end

  test "google login auto-links existing email without google uid" do
    email = "google-autolink@example.com"
    uid = "google-uid-autolink"
    assert {:ok, user} = Accounts.create_user(email)
    assert is_nil(user.google_uid)

    assert {:ok, linked_user} =
             Accounts.login_or_register_with_google(%{
               uid: uid,
               email: email,
               email_verified: true
             })

    assert linked_user.id == user.id
    assert linked_user.google_uid == uid
  end

  test "google login auto-creates user when email is new" do
    email = "google-autocreate@example.com"
    uid = "google-uid-autocreate"

    assert {:ok, user} =
             Accounts.login_or_register_with_google(%{
               uid: uid,
               email: email,
               email_verified: true
             })

    assert user.email == email
    assert user.google_uid == uid
    assert user.current_space_membership_id
    assert %{} = user.current_space_membership
    assert %{} = user.current_space_membership.space
  end

  test "create_invited_user creates account without default space" do
    email = "invited-user-#{System.unique_integer([:positive])}@example.com"

    assert {:ok, user} = Accounts.create_invited_user(email)
    assert user.email == email
    assert is_nil(user.current_space_membership_id)
  end

  test "invite token flow uses invite context and authenticates user" do
    email = "invited-token-#{System.unique_integer([:positive])}@example.com"
    assert {:ok, user} = Accounts.create_invited_user(email)

    invite_token = Accounts.generate_user_invite_token(user)
    older_than_login_window = DateTime.add(DateTime.utc_now(), -16 * 60, :second)

    Repo.get_by!(UserToken, user_id: user.id, context: "invite")
    |> Ecto.Changeset.change(%{inserted_at: older_than_login_window})
    |> Repo.update!()

    assert {:ok, {logged_in_user, persisted_invite_token}} =
             Accounts.login_user(invite_token, "invite")

    assert logged_in_user.id == user.id
    assert persisted_invite_token.context == "invite"
    assert persisted_invite_token.attempts == 1
    refute persisted_invite_token.invalidated_at

    assert {:ok, {reused_user, reused_invite_token}} =
             Accounts.login_user(invite_token, "invite")

    assert reused_user.id == user.id
    assert reused_invite_token.id == persisted_invite_token.id
    assert reused_invite_token.attempts == 2
    refute reused_invite_token.invalidated_at

    session_token = Accounts.generate_user_session_token(reused_invite_token, reused_user)
    assert %{} = Accounts.get_user_by_session_token(session_token)

    assert :ok = Accounts.invalidate_login_token_for_session(session_token)
    assert %{} = Accounts.get_user_by_session_token(session_token)
    assert {:error, "couldn't login to account"} = Accounts.login_user(invite_token, "invite")
  end

  defp create_domain!(%Space{} = space, domain) do
    %Domain{}
    |> Domain.changeset(%{space_id: space.id, domain: domain})
    |> Repo.insert!()
  end

  defp force_space_hash!(space, hash) do
    space
    |> Ecto.Changeset.change(%{hash: hash})
    |> Repo.update!()
  end

  defp video_embed_fixture(%Space{} = space, attrs \\ %{}) do
    attrs =
      Map.merge(
        %{
          hash: "account-video-#{System.unique_integer([:positive])}",
          space_id: space.id,
          type: :video
        },
        attrs
      )

    %Embed{}
    |> Embed.changeset(attrs)
    |> Repo.insert!()
  end

  defp first_domain_label(%Space{domains: domains}) do
    case List.first(domains) do
      %Domain{domain: domain} -> domain
      nil -> ""
    end
  end
end
