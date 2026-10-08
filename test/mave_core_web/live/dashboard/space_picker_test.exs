defmodule MaveCoreWeb.Live.Dashboard.SpacePickerTest do
  use MaveCoreWeb.ConnCase, async: false

  import Phoenix.LiveViewTest

  alias MaveCore.{Accounts, Spaces}
  alias MaveCore.Repo
  alias MaveCoreWeb.DashboardRoutes

  defmodule StubSpaceCreationBackend do
    alias MaveCore.Accounts

    @behaviour MaveCore.SpaceCreation

    @impl true
    def owner_space_options_for_user(_user) do
      [{"alpha.example.com", "owner-alpha"}, {"beta.example.com", "owner-beta"}]
    end

    @impl true
    def create_space_for_user(user, attrs) do
      Accounts.create_space_for_user(user, attrs)
    end
  end

  defmodule BlockedSpaceCreationBackend do
    @behaviour MaveCore.SpaceCreation

    @impl true
    def owner_space_options_for_user(_user), do: []

    @impl true
    def create_space_for_user(_user, _attrs), do: {:error, :unavailable}

    @impl true
    def can_create_space_for_user?(_user, _current_space), do: false
  end

  setup do
    previous_backend = Application.get_env(:mave_core, :space_creation_backend)
    previous_extra_dashboard_items = Application.get_env(:mave_core, :extra_dashboard_items)

    on_exit(fn ->
      if is_nil(previous_backend) do
        Application.delete_env(:mave_core, :space_creation_backend)
      else
        Application.put_env(:mave_core, :space_creation_backend, previous_backend)
      end

      if is_nil(previous_extra_dashboard_items) do
        Application.delete_env(:mave_core, :extra_dashboard_items)
      else
        Application.put_env(:mave_core, :extra_dashboard_items, previous_extra_dashboard_items)
      end
    end)

    :ok
  end

  test "space picker opens the create-space modal instead of creating immediately", %{conn: conn} do
    Application.delete_env(:mave_core, :space_creation_backend)

    {conn, user} = authenticated_conn(conn, "space-modal-open")
    original_count = Accounts.list_user_spaces(user) |> length()

    {:ok, view, _html} = live(conn, "/videos")

    html =
      view
      |> element("#spacepicker-create-space")
      |> render_click()

    assert html =~ "Add new space"
    assert html =~ "Create a standalone space"
    refute html =~ "trial"

    assert Accounts.list_user_spaces(Accounts.get_user_by_email(user.email)) |> length() ==
             original_count
  end

  test "space picker creates a standalone space from the modal", %{conn: conn} do
    Application.delete_env(:mave_core, :space_creation_backend)

    {conn, user} = authenticated_conn(conn, "space-modal-create")

    {:ok, view, _html} = live(conn, "/videos")

    view
    |> element("#spacepicker-create-space")
    |> render_click()

    {:error, {:redirect, %{to: to}}} =
      render_submit(view, "confirm_create_space", %{
        "space" => %{"domain" => "fresh-space.example.com"}
      })

    refreshed_user = Accounts.get_user_by_email(user.email)
    current_space = refreshed_user.current_space_membership.space |> Repo.preload(:domains)

    assert to == DashboardRoutes.signed_in_path(refreshed_user)
    assert Enum.any?(current_space.domains, &(&1.domain == "fresh-space.example.com"))
  end

  test "create-space modal shows an owner dropdown when backend exposes multiple manager spaces",
       %{
         conn: conn
       } do
    Application.put_env(:mave_core, :space_creation_backend, StubSpaceCreationBackend)

    {conn, _user} = authenticated_conn(conn, "space-modal-owner-dropdown")

    {:ok, view, _html} = live(conn, "/videos")

    html =
      view
      |> element("#spacepicker-create-space")
      |> render_click()

    assert html =~ "Select a space that will manage this new space"
    assert html =~ "alpha.example.com"
    assert html =~ "beta.example.com"
    assert html =~ "Select owner space"
    refute html =~ "Personal space"
  end

  test "create-space modal requires an owner when manager options exist", %{conn: conn} do
    Application.put_env(:mave_core, :space_creation_backend, StubSpaceCreationBackend)

    {conn, user} = authenticated_conn(conn, "space-modal-personal-with-owners")
    original_count = Accounts.list_user_spaces(user) |> length()

    {:ok, view, _html} = live(conn, "/videos")

    view
    |> element("#spacepicker-create-space")
    |> render_click()

    html =
      render_submit(view, "confirm_create_space", %{
        "space" => %{"domain" => "personal-choice.example.com", "owner_space_id" => ""}
      })

    assert html =~ "Please choose a managing space"

    assert Accounts.list_user_spaces(Accounts.get_user_by_email(user.email)) |> length() ==
             original_count
  end

  test "space picker hides create action when backend disallows space creation", %{conn: conn} do
    Application.put_env(:mave_core, :space_creation_backend, BlockedSpaceCreationBackend)

    {conn, _user} = authenticated_conn(conn, "space-modal-blocked")

    {:ok, _view, html} = live(conn, "/videos")

    refute html =~ ~s(id="spacepicker-create-space")
  end

  test "space picker marks the current space with an opaque icon instead of a blue row", %{
    conn: conn
  } do
    {conn, _user} = authenticated_conn(conn, "space-picker-current-icon")

    {:ok, _view, html} = live(conn, "/videos")

    assert html =~ "w-6 h-6 transition-opacity duration-150 opacity-100"
    refute html =~ "bg-blue-500 text-white ring-blue-400"
  end

  test "space picker truncates a long current domain before extra actions", %{conn: conn} do
    Application.put_env(:mave_core, :extra_dashboard_items, [
      %{id: :spaces, label: "Spaces", path: "/spaces", placement: :spacepicker, visible?: true}
    ])

    long_domain = "very-long-domain-name-that-should-not-overlap-manage-spaces.example.com"
    {conn, user} = authenticated_conn(conn, "space-picker-long-domain")

    {:ok, _domain} =
      Spaces.create_domain(user.current_space_membership.space, %{"domain" => long_domain})

    {:ok, _view, html} = live(conn, "/videos")

    assert html =~ long_domain
    assert html =~ ~s(title="#{long_domain}")
    assert html =~ "min-w-0 grow truncate py-1.5 px-1"
    assert html =~ ~s(title="Spaces")
  end

  defp authenticated_conn(conn, prefix) do
    email = "#{prefix}-#{System.unique_integer([:positive])}@example.com"
    {:ok, user} = Accounts.create_user(email)
    login_token = Accounts.generate_user_login_token(user)
    {:ok, {logged_in_user, persisted_login_token}} = Accounts.login_user(login_token)
    session_token = Accounts.generate_user_session_token(persisted_login_token, logged_in_user)

    conn =
      conn
      |> with_manage_host()
      |> init_test_session(user_token: session_token)

    {conn, logged_in_user}
  end

  defp with_manage_host(conn) do
    case System.get_env("MAVE_MANAGE_HOST") do
      host when is_binary(host) and host != "" -> %{conn | host: host}
      _ -> conn
    end
  end
end
