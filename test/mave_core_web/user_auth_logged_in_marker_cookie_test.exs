defmodule MaveCoreWeb.UserAuthLoggedInMarkerCookieTest do
  use MaveCoreWeb.ConnCase, async: false

  alias MaveCore.Accounts
  alias MaveCoreWeb.DashboardRoutes

  @cookie "_mave_a"
  @cookie_domain ".mave.io"
  @max_age 60 * 60 * 24 * 60

  setup do
    previous = Application.get_env(:mave_core, :logged_in_marker_cookie)

    Application.put_env(:mave_core, :logged_in_marker_cookie,
      enabled: true,
      domain: @cookie_domain
    )

    on_exit(fn -> restore_env(:logged_in_marker_cookie, previous) end)
  end

  test "token login writes the marketing-visible logged-in marker cookie", %{conn: conn} do
    email = "marker-login-test@example.com"
    assert {:ok, user} = Accounts.create_user(email)
    login_token = Accounts.generate_user_login_token(user)

    conn = get(conn, "/login?token=#{login_token}")

    assert redirected_to(conn) == DashboardRoutes.signed_in_path(user)

    assert %{
             value: "true",
             max_age: @max_age,
             http_only: false,
             same_site: "Lax",
             secure: true,
             domain: @cookie_domain
           } = conn.resp_cookies[@cookie]
  end

  test "logout clears the logged-in marker cookie on the configured domain", %{conn: conn} do
    email = "marker-logout-test@example.com"
    assert {:ok, user} = Accounts.create_user(email)
    login_token = Accounts.generate_user_login_token(user)

    conn = get(conn, "/login?token=#{login_token}")
    session_token = get_session(conn, :user_token)

    assert is_binary(session_token)

    conn = delete(conn, "/logout")

    assert redirected_to(conn) == "/login"
    assert %{max_age: 0, domain: @cookie_domain} = conn.resp_cookies[@cookie]
    assert is_nil(Accounts.get_user_by_session_token(session_token))
  end

  defp restore_env(key, nil), do: Application.delete_env(:mave_core, key)
  defp restore_env(key, value), do: Application.put_env(:mave_core, key, value)
end
