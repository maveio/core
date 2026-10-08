defmodule MaveCoreWeb.UserAuthRememberMeCookieTest do
  use MaveCoreWeb.ConnCase, async: true

  alias MaveCore.Accounts
  alias MaveCoreWeb.UserAuth

  test "the remember-me cookie explicitly uses SameSite Lax", %{conn: conn} do
    email = "remember-me-#{System.unique_integer([:positive])}@example.com"
    {:ok, user} = Accounts.create_user(email)

    {:ok, {user, login_token}} =
      user
      |> Accounts.generate_user_login_token()
      |> Accounts.login_user()

    conn =
      conn
      |> Map.put(:secret_key_base, MaveCoreWeb.Endpoint.config(:secret_key_base))
      |> init_test_session(%{})
      |> UserAuth.log_in_user(login_token, user)

    assert %{same_site: "Lax", max_age: max_age} = conn.resp_cookies["_mave_core_cookie"]
    assert max_age > 0
  end
end
