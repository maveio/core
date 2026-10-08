defmodule MaveCoreWeb.SetupControllerTest do
  use MaveCoreWeb.ConnCase, async: false

  alias MaveCore.Accounts
  alias MaveCore.Installation
  alias MaveCore.Repo
  alias MaveCoreWeb.Plugs.InstallationSetup

  @code String.duplicate("a", 48)

  setup do
    previous = Application.get_env(:mave_core, :installation_setup)
    Application.put_env(:mave_core, :installation_setup, enabled: true, code: @code)

    on_exit(fn ->
      if previous,
        do: Application.put_env(:mave_core, :installation_setup, previous),
        else: Application.delete_env(:mave_core, :installation_setup)
    end)
  end

  test "a fresh installation directs the owner to an accessible setup form", %{conn: conn} do
    assert redirected_to(get(conn, "/")) == "/setup"
    assert redirected_to(get(conn, "/login")) == "/setup"
    assert redirected_to(get(conn, "/auth/google")) == "/setup"
    conn = get(conn, "/setup")
    document = conn |> html_response(200) |> LazyHTML.from_document()
    refute Enum.empty?(LazyHTML.query(document, "#setup-form input[name='setup[email]']"))
    refute Enum.empty?(LazyHTML.query(document, "#setup-form input[name='setup[code]']"))
    assert get_resp_header(conn, "cache-control") == ["no-store"]
  end

  test "setup is disabled by default", %{conn: conn} do
    Application.delete_env(:mave_core, :installation_setup)
    assert response(get(conn, "/setup"), 404)

    assert response(
             post(conn, "/setup", %{setup: %{email: "owner@example.com", code: @code}}),
             404
           )

    refute Repo.exists?(Accounts.User)
  end

  test "a forwarding host cannot expose setup even when it is enabled" do
    conn =
      Plug.Test.conn(:get, "/setup")
      |> Plug.Test.init_test_session(%{})
      |> Plug.Conn.put_private(:phoenix_endpoint, OtherHost.Endpoint)
      |> MaveCoreWeb.Router.call(MaveCoreWeb.Router.init([]))

    assert conn.status == 404
    refute InstallationSetup.standalone?(conn)
  end

  test "a forwarding host also rejects setup writes" do
    conn =
      Plug.Test.conn(:post, "/setup", %{
        "setup" => %{"email" => "owner@example.com", "code" => @code}
      })
      |> Plug.Test.init_test_session(%{})
      |> Plug.Conn.put_private(:plug_skip_csrf_protection, true)
      |> Plug.Conn.put_private(:phoenix_endpoint, OtherHost.Endpoint)
      |> MaveCoreWeb.Router.call(MaveCoreWeb.Router.init([]))

    assert conn.status == 404
    refute Repo.exists?(Accounts.User)
  end

  test "a valid setup code cannot bypass CSRF protection", %{conn: conn} do
    assert_raise Plug.CSRFProtection.InvalidCSRFTokenError, fn ->
      conn
      |> Plug.Conn.put_private(:plug_skip_csrf_protection, false)
      |> post("/setup", %{setup: %{email: "owner@example.com", code: @code}})
    end

    refute Repo.exists?(Accounts.User)
  end

  test "an unavailable or short setup code never authorizes setup" do
    Application.put_env(:mave_core, :installation_setup,
      enabled: true,
      code_file: "/missing/setup/code"
    )

    assert {:error, :invalid_code} = Installation.authorize(@code)
    Application.put_env(:mave_core, :installation_setup, enabled: true, code: "short")
    assert {:error, :invalid_code} = Installation.authorize("short")
  end

  test "invalid code creates nothing and is never echoed", %{conn: conn} do
    conn =
      post(conn, "/setup", %{setup: %{email: "owner@example.com", code: "wrong-private-code"}})

    html = html_response(conn, 422)
    refute html =~ "wrong-private-code"
    assert html =~ "Check the setup code and try again."
    refute Repo.exists?(Accounts.User)
    assert Installation.pending?()
  end

  test "malformed email is rejected before provisioning", %{conn: conn} do
    conn = post(conn, "/setup", %{setup: %{email: "invalid", code: @code}})
    assert html_response(conn, 422)
    refute Repo.exists?(Accounts.User)
    assert Installation.pending?()
  end

  test "creates a confirmed owner and workspace, signs in and permanently closes setup", %{
    conn: conn
  } do
    conn = post(conn, "/setup", %{setup: %{email: " owner@example.com ", code: @code}})
    assert conn.status == 302
    assert get_session(conn, :user_token)
    owner = Accounts.get_user_by_email("owner@example.com")
    assert owner.confirmed_at
    assert owner.current_space_membership.role == "owner"
    refute Installation.pending?()
    assert Repo.exists?("installation_setup")
    assert redirected_to(get(build_conn(), "/setup")) == "/login"

    assert {:error, :already_completed} =
             Installation.complete(%{"email" => "second@example.com", "code" => @code})

    assert Repo.aggregate(Accounts.User, :count) == 1

    # Completion is independent of whether the owner account still exists.
    Repo.delete!(owner)
    refute Repo.exists?(Accounts.User)
    refute Installation.pending?()
  end

  test "existing installations never become claimable", %{conn: conn} do
    {:ok, owner} = Accounts.create_user("existing@example.com", %{skip_email_validation: true})
    assert redirected_to(get(conn, "/setup")) == "/login"
    owner |> Ecto.Changeset.change(deleted_at: DateTime.utc_now()) |> Repo.update!()
    refute Installation.pending?()
  end
end
