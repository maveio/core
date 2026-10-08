defmodule MaveCoreWeb.Api.CliAuthorizationsControllerTest do
  use MaveCoreWeb.ConnCase, async: false

  alias MaveCore.Accounts
  alias MaveCore.CliAuthorizations

  setup do
    previous_domain = Application.get_env(:mave_core, :domain)
    Application.put_env(:mave_core, :domain, "https://dash.example.test")

    on_exit(fn ->
      if previous_domain do
        Application.put_env(:mave_core, :domain, previous_domain)
      else
        Application.delete_env(:mave_core, :domain)
      end
    end)
  end

  test "POST /api/v1/cli/authorizations starts browser authorization", %{conn: conn} do
    conn = post(conn, ~p"/api/v1/cli/authorizations", %{})

    assert %{
             "device_code" => device_code,
             "user_code" => user_code,
             "verification_uri" => "https://dash.example.test/cli/auth",
             "verification_uri_complete" => complete,
             "expires_in" => 600,
             "interval" => 2
           } = json_response(conn, 201)

    assert is_binary(device_code)
    assert complete == "https://dash.example.test/cli/auth/#{user_code}"
    assert get_resp_header(conn, "cache-control") == ["no-store"]
  end

  test "accepts optional metadata without changing the 0.1.0 response contract", %{conn: conn} do
    response =
      conn
      |> post(~p"/api/v1/cli/authorizations", %{
        "client" => "mave-cli",
        "version" => "0.1.0",
        "device_name" => " Test Mac "
      })
      |> json_response(201)

    assert {:ok, authorization} = CliAuthorizations.get_for_browser(response["user_code"])

    assert authorization.client_metadata == %{
             "client" => "mave-cli",
             "version" => "0.1.0",
             "device_name" => "Test Mac"
           }

    refute Map.has_key?(response, "client_metadata")
  end

  test "the token endpoint reports pending, denied, and invalid requests", %{conn: conn} do
    assert {:ok, %{authorization: authorization, device_code: device_code}} =
             CliAuthorizations.create_authorization()

    pending_conn =
      post(conn, ~p"/api/v1/cli/authorizations/token", %{"device_code" => device_code})

    assert %{"error" => "authorization_pending"} = json_response(pending_conn, 400)

    assert {:ok, _authorization} = CliAuthorizations.deny(authorization.user_code)

    denied_conn =
      build_conn()
      |> post(~p"/api/v1/cli/authorizations/token", %{"device_code" => device_code})

    assert %{"error" => "access_denied"} = json_response(denied_conn, 403)

    invalid_conn =
      build_conn()
      |> post(~p"/api/v1/cli/authorizations/token", %{"device_code" => "unknown"})

    assert %{"error" => "invalid_grant"} = json_response(invalid_conn, 400)
  end

  test "an approved authorization returns a one-time API token", %{conn: conn} do
    email = "cli-auth-controller-#{System.unique_integer([:positive])}@example.com"
    assert {:ok, user} = Accounts.create_user(email)
    space = user.current_space_membership.space

    assert {:ok, %{authorization: authorization, device_code: device_code}} =
             CliAuthorizations.create_authorization()

    assert {:ok, _authorization} =
             CliAuthorizations.approve(authorization.user_code, space)

    conn = post(conn, ~p"/api/v1/cli/authorizations/token", %{"device_code" => device_code})

    assert %{
             "access_token" => access_token,
             "token_type" => "Bearer",
             "space_id" => space_id,
             "space_hash" => space_hash
           } = json_response(conn, 200)

    assert is_binary(access_token)
    assert space_id == space.id
    assert space_hash == space.hash
    assert get_resp_header(conn, "cache-control") == ["no-store"]
  end
end
