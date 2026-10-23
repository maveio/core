defmodule MaveCoreWeb.McpAuthLiveTest do
  use MaveCoreWeb.ConnCase, async: true
  import Phoenix.LiveViewTest
  import MaveCore.MCPFixtures
  alias MaveCore.Accounts
  alias MaveCore.MCP.OAuth

  test "login preserves the complete authorization request", %{conn: conn} do
    f = mcp_request_fixture()
    path = "/oauth/mcp/authorize?" <> URI.encode_query(f.params)
    conn = get(conn, path)
    assert redirected_to(conn) == "/login"
    assert get_session(conn, :user_return_to) == path
  end

  test "reuses the CLI card, shows read-only consent and returns a usable code", %{conn: conn} do
    f = mcp_request_fixture()
    user = mcp_user_fixture()
    conn = login(conn, user)
    {:ok, view, _} = live(conn, "/oauth/mcp/authorize?" <> URI.encode_query(f.params))
    assert has_element?(view, "#mcp-auth-window")
    assert has_element?(view, "#mcp-client-name", "Test assistant")
    assert has_element?(view, "#mcp-client-destination", "127.0.0.1")
    assert has_element?(view, "#mcp-read-only")
    assert has_element?(view, "#mcp-auth-approval-form")

    view
    |> form("#mcp-auth-approval-form",
      authorization: %{space_id: user.current_space_membership.space.id}
    )
    |> render_submit()

    {url, _} = assert_redirect(view)
    query = URI.decode_query(URI.parse(url).query)
    assert query["state"] == "client-state"

    assert {:ok, tokens} =
             OAuth.exchange(%{
               "grant_type" => "authorization_code",
               "client_id" => f.client.id,
               "code" => query["code"],
               "code_verifier" => f.verifier,
               "resource" => f.params["resource"],
               "redirect_uri" => f.params["redirect_uri"]
             })

    assert {:ok, _} = OAuth.authenticate(tokens.access_token)
  end

  test "write consent is explicit and rejecting returns the original state", %{conn: conn} do
    f = mcp_request_fixture(scope: "mave:read mave:write")

    {:ok, view, _} =
      live(login(conn, mcp_user_fixture()), "/oauth/mcp/authorize?" <> URI.encode_query(f.params))

    refute has_element?(view, "#mcp-read-only")
    assert has_element?(view, "#mcp-permissions", "delete")
    view |> element("#mcp-auth-deny") |> render_click()
    {url, _} = assert_redirect(view)
    assert URI.decode_query(URI.parse(url).query)["error"] == "access_denied"
    assert URI.decode_query(URI.parse(url).query)["state"] == "client-state"
  end

  test "invalid clients render an error without redirecting", %{conn: conn} do
    {:ok, view, _} =
      live(
        login(conn, mcp_user_fixture()),
        "/oauth/mcp/authorize?client_id=unknown&redirect_uri=https://evil.example"
      )

    assert has_element?(view, "#mcp-auth-invalid")
    refute has_element?(view, "#mcp-auth-authorize")
  end

  test "tampering with the chosen space cannot approve another tenant", %{conn: conn} do
    f = mcp_request_fixture()
    other = mcp_user_fixture()

    {:ok, view, _} =
      live(login(conn, mcp_user_fixture()), "/oauth/mcp/authorize?" <> URI.encode_query(f.params))

    render_submit(view, "authorize", %{
      "authorization" => %{"space_id" => other.current_space_membership.space.id}
    })

    assert has_element?(view, "#mcp-auth-error")
  end

  test "connected apps can be revoked and immediately stop working", %{conn: conn} do
    f = mcp_grant_fixture()
    {:ok, view, _} = live(login(conn, f.user), "/mcp/connections")
    assert has_element?(view, "#mcp-connection-#{f.grant.id}")
    view |> element("#mcp-revoke-#{f.grant.id}") |> render_click()
    assert has_element?(view, "#mcp-connections-empty")
    assert {:error, :invalid_token} = OAuth.authenticate(f.tokens.access_token)
  end

  defp login(conn, user) do
    token = Accounts.generate_user_login_token(user)
    {:ok, {user, persisted}} = Accounts.login_user(token)
    init_test_session(conn, user_token: Accounts.generate_user_session_token(persisted, user))
  end
end
