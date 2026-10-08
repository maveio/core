defmodule MaveCoreWeb.UserAuthTest do
  use MaveCoreWeb.ConnCase, async: true

  import Phoenix.LiveViewTest

  alias MaveCore.{Accounts, Spaces}
  alias MaveCoreWeb.DashboardRoutes
  alias MaveCoreWeb.UserAuth

  defp authenticated_conn(conn, email) do
    assert {:ok, user} = Accounts.create_user(email)
    login_token = Accounts.generate_user_login_token(user)
    assert {:ok, {logged_in_user, persisted_login_token}} = Accounts.login_user(login_token)

    session_token = Accounts.generate_user_session_token(persisted_login_token, logged_in_user)
    init_test_session(conn, user_token: session_token)
  end

  test "token GET logs in directly and strips the token from the redirect", %{conn: conn} do
    email = "token-loop-test@example.com"
    assert {:ok, user} = Accounts.create_user(email)
    login_token = Accounts.generate_user_login_token(user)

    conn = get(conn, "/login?token=#{login_token}")

    assert redirected_to(conn) == DashboardRoutes.signed_in_path(user)
    assert get_session(conn, :user_token)
    assert get_resp_header(conn, "referrer-policy") == ["no-referrer"]
    assert get_resp_header(conn, "cache-control") == ["no-store"]

    persisted_login_token = login_token_for(user)
    assert persisted_login_token.attempts == 1
    refute persisted_login_token.invalidated_at
  end

  test "token login redirects to an authorized fallback after the selected space is deleted", %{
    conn: conn
  } do
    {:ok, user} = Accounts.create_user("deleted-space-login@example.com")
    fallback_path = DashboardRoutes.signed_in_path(user)
    {:ok, selected_user} = Accounts.create_space_for_user(user)
    token = Accounts.generate_user_login_token(selected_user)

    selected_user.current_space_membership.space
    |> Ecto.Changeset.change(deleted_at: DateTime.utc_now())
    |> MaveCore.Repo.update!()

    conn = get(conn, "/login?token=#{token}")
    assert redirected_to(conn) == fallback_path
    assert session_token = get_session(conn, :user_token)
    session_user = Accounts.get_user_by_session_token(session_token)
    assert session_user.current_space_membership_id == user.current_space_membership_id
    refute Accounts.can_access_space?(session_user, selected_user.current_space_membership.space)
  end

  test "a scanner GET does not prevent the user from reusing the link", %{
    conn: conn
  } do
    email = "token-scanner-test@example.com"
    assert {:ok, user} = Accounts.create_user(email)
    login_token = Accounts.generate_user_login_token(user)
    path = "/login?token=#{login_token}"

    _scanner_conn =
      build_conn()
      |> with_manage_host()
      |> get(path)

    scanned_token = login_token_for(user)
    assert scanned_token.attempts == 1
    refute scanned_token.invalidated_at

    user_conn = get(conn, path)

    assert redirected_to(user_conn) == DashboardRoutes.signed_in_path(user)
    assert get_session(user_conn, :user_token)

    reused_token = login_token_for(user)
    assert reused_token.attempts == 2
    refute reused_token.invalidated_at
  end

  test "an expired token redirects to login with a new-link prompt and visible email form", %{
    conn: conn
  } do
    email = "token-expired-message-test@example.com"
    assert {:ok, user} = Accounts.create_user(email)
    login_token = Accounts.generate_user_login_token(user)

    user
    |> login_token_for()
    |> Ecto.Changeset.change(%{
      inserted_at: DateTime.add(DateTime.utc_now(), -16 * 60, :second)
    })
    |> MaveCore.Repo.update!()

    conn = get(conn, "/login?token=#{login_token}")

    assert redirected_to(conn) == "/login?error=link"

    {:ok, view, html} = live(recycle(conn), redirected_to(conn))

    assert html =~
             "This login link is invalid or has expired. Enter your email to request a new link."

    assert has_element?(view, "#login_form")
  end

  test "token login keeps internal return path and strips token query param", %{conn: conn} do
    email = "token-return-path-test@example.com"
    assert {:ok, user} = Accounts.create_user(email)
    login_token = Accounts.generate_user_login_token(user)

    conn = get(conn, "/settings?token=#{login_token}")

    assert redirected_to(conn) == "/settings"
    assert get_session(conn, :user_token)
  end

  test "invite token login keeps space invite path and strips token query param", %{conn: conn} do
    inviter_email = "invite-owner-#{System.unique_integer([:positive])}@example.com"
    invitee_email = "invite-user-#{System.unique_integer([:positive])}@example.com"

    assert {:ok, inviter} = Accounts.create_user(inviter_email)
    assert {:ok, invitee} = Accounts.create_invited_user(invitee_email)
    space = inviter.current_space_membership.space
    assert {:ok, membership} = Spaces.create_membership_invite(space, inviter, invitee_email)
    invite_token = Accounts.generate_user_invite_token(invitee)

    conn = get(conn, "/space?invite=#{membership.invite.id}&token=#{invite_token}")

    assert redirected_to(conn) == "/space?invite=#{membership.invite.id}"
    assert get_session(conn, :user_token)
  end

  test "invite token can reopen a pending invite but not an accepted invite", %{conn: conn} do
    inviter_email = "invite-reopen-owner-#{System.unique_integer([:positive])}@example.com"
    invitee_email = "invite-reopen-user-#{System.unique_integer([:positive])}@example.com"

    assert {:ok, inviter} = Accounts.create_user(inviter_email)
    assert {:ok, invitee} = Accounts.create_invited_user(invitee_email)
    space = inviter.current_space_membership.space
    assert {:ok, membership} = Spaces.create_membership_invite(space, inviter, invitee_email)
    invite_token = Accounts.generate_user_invite_token(invitee)
    path = "/space?invite=#{membership.invite.id}&token=#{invite_token}"

    first_conn = get(conn, path)

    assert redirected_to(first_conn) == "/space?invite=#{membership.invite.id}"
    assert get_session(first_conn, :user_token)

    second_conn =
      build_conn()
      |> with_manage_host()
      |> get(path)

    assert redirected_to(second_conn) == "/space?invite=#{membership.invite.id}"
    assert get_session(second_conn, :user_token)

    {:ok, view, _html} = live(first_conn, redirected_to(first_conn))

    view
    |> element("#accept-space-invite-button")
    |> render_click()

    accepted_replay_conn =
      build_conn()
      |> with_manage_host()
      |> get(path)

    assert redirected_to(accepted_replay_conn) == "/space?invite=#{membership.invite.id}&stale=1"
    refute get_session(accepted_replay_conn, :user_token)
  end

  test "invite token link reaches the invite screen without signing in after pending invite is removed",
       %{
         conn: conn
       } do
    inviter_email = "invite-removed-owner-#{System.unique_integer([:positive])}@example.com"
    invitee_email = "invite-removed-user-#{System.unique_integer([:positive])}@example.com"

    assert {:ok, inviter} = Accounts.create_user(inviter_email)
    assert {:ok, invitee} = Accounts.create_invited_user(invitee_email)
    space = inviter.current_space_membership.space
    assert {:ok, membership} = Spaces.create_membership_invite(space, inviter, invitee_email)
    invite_token = Accounts.generate_user_invite_token(invitee)
    path = "/space?invite=#{membership.invite.id}&token=#{invite_token}"

    assert {:ok, _removed} =
             Spaces.remove_member(space, membership.id, %{current_user_id: inviter.id})

    conn = get(conn, path)

    assert redirected_to(conn) == "/space?invite=#{membership.invite.id}&stale=1"
    refute get_session(conn, :user_token)
  end

  test "logout invalidates session token and clears auth cookie", %{conn: conn} do
    email = "logout-test@example.com"
    assert {:ok, user} = Accounts.create_user(email)
    login_token = Accounts.generate_user_login_token(user)

    conn = get(conn, "/login?token=#{login_token}")
    session_token = get_session(conn, :user_token)

    assert is_binary(session_token)
    assert %{} = Accounts.get_user_by_session_token(session_token)

    conn = delete(conn, "/logout")

    assert redirected_to(conn) == "/login"
    refute get_session(conn, :user_token)
    assert is_nil(Accounts.get_user_by_session_token(session_token))
    assert %{max_age: 0} = conn.resp_cookies["_mave_core_cookie"]
  end

  test "login rejects scheme-relative return paths", %{conn: conn} do
    email = "login-return-path-test@example.com"
    assert {:ok, user} = Accounts.create_user(email)
    login_token = Accounts.generate_user_login_token(user)
    assert {:ok, {logged_in_user, persisted_login_token}} = Accounts.login_user(login_token)

    conn =
      conn
      |> Map.put(:secret_key_base, MaveCoreWeb.Endpoint.config(:secret_key_base))
      |> init_test_session(user_return_to: "//evil.example/capture")
      |> UserAuth.log_in_user(persisted_login_token, logged_in_user)

    assert redirected_to(conn) == DashboardRoutes.signed_in_path(logged_in_user)
  end

  test "authenticated user visiting /login is redirected to /videos", %{conn: conn} do
    conn = authenticated_conn(conn, "redirect-login-test@example.com")
    conn = get(conn, "/login")

    assert redirected_to(conn) == DashboardRoutes.signed_in_path(current_user(conn))
  end

  test "authenticated user visiting /signup is redirected to /videos", %{conn: conn} do
    conn = authenticated_conn(conn, "redirect-signup-test@example.com")
    conn = get(conn, "/signup")

    assert redirected_to(conn) == DashboardRoutes.signed_in_path(current_user(conn))
  end

  test "remember-me cookie without session still redirects /login to /videos", %{conn: conn} do
    email = "redirect-cookie-only-test@example.com"
    assert {:ok, user} = Accounts.create_user(email)
    login_token = Accounts.generate_user_login_token(user)

    conn = get(conn, "/login?token=#{login_token}")
    remember_cookie = conn.resp_cookies["_mave_core_cookie"].value
    assert is_binary(remember_cookie)

    conn =
      build_conn()
      |> put_req_cookie("_mave_core_cookie", remember_cookie)
      |> get("/login")

    assert redirected_to(conn) == DashboardRoutes.signed_in_path(user)
  end

  defp current_user(conn), do: Accounts.get_user_by_session_token(get_session(conn, :user_token))

  defp login_token_for(user) do
    MaveCore.Repo.get_by!(MaveCore.Accounts.UserToken, user_id: user.id, context: "login")
  end

  defp with_manage_host(conn) do
    case System.get_env("MAVE_MANAGE_HOST") do
      host when is_binary(host) and host != "" -> %{conn | host: host}
      _ -> conn
    end
  end
end
