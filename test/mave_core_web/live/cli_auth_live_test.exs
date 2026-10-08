defmodule MaveCoreWeb.CliAuthLiveTest do
  use MaveCoreWeb.ConnCase, async: false

  import Phoenix.LiveViewTest

  alias MaveCore.Accounts
  alias MaveCore.CliAuthorizations

  test "requires login and preserves the authorization path", %{conn: conn} do
    conn = get(conn, "/cli/auth/ABCDE-FGHIJ")

    assert redirected_to(conn) == "/login"
    assert get_session(conn, :user_return_to) == "/cli/auth/ABCDE-FGHIJ"
  end

  test "accepts a manually entered device code", %{conn: conn} do
    conn = authenticated_conn(conn)
    assert {:ok, %{authorization: authorization}} = CliAuthorizations.create_authorization()
    {:ok, view, _html} = live(conn, "/cli/auth")

    assert has_element?(view, "#cli-auth-code-form")

    view
    |> form("#cli-auth-code-form", authorization: %{user_code: authorization.user_code})
    |> render_submit()

    assert_redirect(view, "/cli/auth/#{authorization.user_code}")
  end

  test "approves the current space and lets the CLI exchange once", %{conn: conn} do
    {conn, space} = authenticated_conn_with_space(conn)

    assert {:ok, %{authorization: authorization, device_code: device_code}} =
             CliAuthorizations.create_authorization()

    {:ok, view, _html} = live(conn, "/cli/auth/#{authorization.user_code}")

    assert has_element?(view, "#cli-auth-user-code", authorization.user_code)
    assert has_element?(view, "#cli-auth-approval-form")
    assert has_element?(view, "#cli-auth-authorize")

    view
    |> form("#cli-auth-approval-form", authorization: %{space_id: space.id})
    |> render_submit()

    assert has_element?(view, "#cli-auth-approved")

    assert {:ok, %{access_token: token, space_id: space_id}} =
             CliAuthorizations.exchange(device_code)

    assert is_binary(token)
    assert space_id == space.id
    {:ok, refreshed, _html} = live(conn, "/cli/auth/#{authorization.user_code}")
    assert has_element?(refreshed, "#cli-auth-approved")
    assert has_element?(refreshed, "#cli-auth-settings[href='/#{space.id}/settings/developer']")
  end

  test "cancels authorization without creating a credential", %{conn: conn} do
    conn = authenticated_conn(conn)

    assert {:ok, %{authorization: authorization, device_code: device_code}} =
             CliAuthorizations.create_authorization()

    {:ok, view, _html} = live(conn, "/cli/auth/#{authorization.user_code}")

    view
    |> element("#cli-auth-deny")
    |> render_click()

    assert has_element?(view, "#cli-auth-denied")
    assert {:error, :access_denied} = CliAuthorizations.exchange(device_code)
  end

  test "shows the supplied device name and rejects a different user's space", %{conn: conn} do
    conn = authenticated_conn(conn)

    {:ok, other} =
      Accounts.create_user("other-cli-#{System.unique_integer([:positive])}@example.com")

    {:ok, %{authorization: authorization, device_code: code}} =
      CliAuthorizations.create_authorization(client_metadata: %{"device_name" => "Studio Mac"})

    {:ok, view, _html} = live(conn, "/cli/auth/#{authorization.user_code}")
    assert has_element?(view, "#cli-auth-device-name", "Studio Mac")
    assert has_element?(view, "label[for='authorization_space_id']", "Space")

    render_submit(view, "authorize", %{
      "authorization" => %{"space_id" => other.current_space_membership.space.id}
    })

    assert has_element?(view, "#cli-auth-approval-form")
    assert {:error, :authorization_pending} = CliAuthorizations.exchange(code)
  end

  test "invalid and expired codes cannot be authorized", %{conn: conn} do
    conn = authenticated_conn(conn)
    {:ok, invalid, _} = live(conn, "/cli/auth/ABCDE-F0123")
    assert has_element?(invalid, "#cli-auth-invalid")
    render_click(invalid, "deny")
    assert has_element?(invalid, "#cli-auth-invalid")

    {:ok, %{authorization: authorization}} =
      CliAuthorizations.create_authorization(now: DateTime.add(DateTime.utc_now(), -601))

    {:ok, expired, _} = live(conn, "/cli/auth/#{authorization.user_code}")
    assert has_element?(expired, "#cli-auth-expired")
    refute has_element?(expired, "#cli-auth-authorize")
  end

  defp authenticated_conn(conn) do
    {conn, _space} = authenticated_conn_with_space(conn)
    conn
  end

  defp authenticated_conn_with_space(conn) do
    email = "cli-auth-live-#{System.unique_integer([:positive])}@example.com"
    {:ok, user} = Accounts.create_user(email)
    login_token = Accounts.generate_user_login_token(user)
    {:ok, {logged_in_user, persisted_login_token}} = Accounts.login_user(login_token)
    session_token = Accounts.generate_user_session_token(persisted_login_token, logged_in_user)

    conn = init_test_session(conn, user_token: session_token)
    {conn, logged_in_user.current_space_membership.space}
  end
end
