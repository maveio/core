defmodule MaveCoreWeb.Live.SpaceInvite.IndexTest do
  use MaveCoreWeb.ConnCase, async: true

  import Phoenix.LiveViewTest

  alias MaveCore.{Accounts, Repo, Spaces}
  alias MaveCore.Spaces.Membership
  alias MaveCoreWeb.DashboardRoutes

  test "/space requires explicit acceptance before granting access", %{conn: conn} do
    owner_email = "space-invite-owner-#{System.unique_integer([:positive])}@example.com"
    invitee_email = "space-invite-user-#{System.unique_integer([:positive])}@example.com"

    assert {:ok, owner} = Accounts.create_user(owner_email)
    assert {:ok, invitee} = Accounts.create_invited_user(invitee_email)

    space = owner.current_space_membership.space
    assert {:ok, membership} = Spaces.create_membership_invite(space, owner, invitee_email)
    assert is_nil(membership.user_id)

    conn = authenticated_conn(conn, invitee)

    {:ok, view, html} = live(conn, "/space?invite=#{membership.invite.id}")

    assert html =~ "Space invite"
    assert html =~ invitee_email
    assert has_element?(view, "#space-invite-panel")
    assert has_element?(view, "#accept-space-invite-button")

    view
    |> element("#accept-space-invite-button")
    |> render_click()

    accepted_membership = Repo.get!(Membership, membership.id)
    assert accepted_membership.user_id == invitee.id

    updated_invitee = Accounts.get_user_by_email(invitee_email)
    assert_redirect(view, DashboardRoutes.signed_in_path(updated_invitee))
    assert updated_invitee.current_space_membership_id == membership.id
  end

  test "/space rejects an invited user when the invite was removed before acceptance", %{
    conn: conn
  } do
    owner_email = "space-invite-removed-owner-#{System.unique_integer([:positive])}@example.com"
    invitee_email = "space-invite-removed-user-#{System.unique_integer([:positive])}@example.com"

    assert {:ok, owner} = Accounts.create_user(owner_email)
    assert {:ok, _invitee} = Accounts.create_invited_user(invitee_email)

    space = owner.current_space_membership.space
    assert {:ok, membership} = Spaces.create_membership_invite(space, owner, invitee_email)
    invite_id = membership.invite.id

    assert {:ok, _removed} =
             Spaces.remove_member(space, membership.id, %{current_user_id: owner.id})

    assert {:ok, view, html} = live(conn, "/space?invite=#{invite_id}&stale=1")

    recovered_invitee = Accounts.get_user_by_email(invitee_email)

    assert html =~ "Invite no longer available"
    assert html =~ "Ask the space owner to send a new invite."
    refute has_element?(view, "#accept-space-invite-button")
    assert has_element?(view, "#space-invite-unavailable-link")
    assert html =~ "back to login"
    assert is_nil(recovered_invitee.current_space_membership_id)
  end

  defp authenticated_conn(conn, user) do
    login_token = Accounts.generate_user_login_token(user)
    assert {:ok, {logged_in_user, persisted_login_token}} = Accounts.login_user(login_token)
    session_token = Accounts.generate_user_session_token(persisted_login_token, logged_in_user)

    conn
    |> with_manage_host()
    |> init_test_session(user_token: session_token)
  end

  defp with_manage_host(conn) do
    case System.get_env("MAVE_MANAGE_HOST") do
      host when is_binary(host) and host != "" -> %{conn | host: host}
      _ -> conn
    end
  end
end
