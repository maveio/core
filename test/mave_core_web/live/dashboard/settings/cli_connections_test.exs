defmodule MaveCoreWeb.Dashboard.Settings.CliConnectionsTest do
  use MaveCoreWeb.ConnCase, async: false

  import Phoenix.LiveViewTest

  alias MaveCore.{Accounts, CliAuthorizations, Repo, Spaces}
  alias MaveCore.Spaces.Key

  test "CLI connections use the API key table and its existing actions", %{conn: conn} do
    {conn, space} = authenticated_conn(conn)

    named =
      connection(space, %{
        "client" => "mave-cli",
        "version" => "0.1.0",
        "device_name" => "Studio Mac"
      })

    unnamed = connection(space, %{})

    {:ok, ordinary} =
      Spaces.create_key(space, %{description: "Mave CLI", access_level: :read_only})

    {:ok, internal} = Spaces.ensure_internal_key(space, :dashboard_uploads)

    {:ok, other_user} =
      Accounts.create_user("other-cli-settings-#{System.unique_integer([:positive])}@example.com")

    other = connection(other_user.current_space_membership.space, %{"device_name" => "Other Mac"})
    {:ok, _} = Spaces.make_key_read_only(named)

    {:ok, view, _} = live(conn, "/settings/developer")
    refute has_element?(view, "#settings-cli-connections")
    assert has_element?(view, "#api-key-#{named.id}", "Mave CLI")
    assert has_element?(view, "#cli-key-details-#{named.id}", "Studio Mac · v0.1.0")
    assert has_element?(view, "#api-key-#{named.id}", "read only")
    assert has_element?(view, "#api-key-#{unnamed.id}", "Mave CLI")
    assert has_element?(view, "#cli-key-details-#{unnamed.id}", "Device name unavailable")
    assert has_element?(view, "#api-key-#{ordinary.id}")
    assert has_element?(view, "#key-#{named.id}")
    refute has_element?(view, "#cli-key-details-#{ordinary.id}")
    refute has_element?(view, "#api-key-#{other.id}")
    refute has_element?(view, "#api-key-#{internal.id}")

    view |> element("#key-#{named.id}-toggle") |> render_click()
    assert has_element?(view, "#key-#{named.id}-toggle[aria-pressed='true']")

    view |> element("#edit-key-#{named.id}") |> render_click()

    view
    |> form("#api-key-form", api_key: %{description: "My terminal", access_level: "read_write"})
    |> render_submit()

    updated = Repo.get!(Key, named.id)
    assert updated.description == "My terminal"
    assert updated.access_level == :read_write
    assert updated.cli_metadata == named.cli_metadata
    assert has_element?(view, "#api-key-#{named.id}", "My terminal")
    assert has_element?(view, "#cli-key-details-#{named.id}", "Studio Mac")

    # The shared delete action still excludes other spaces and internal keys.
    for id <- [other.id, internal.id] do
      view
      |> element("#api-key-#{named.id} [phx-click='delete_key']")
      |> render_click(%{"id" => id})

      view |> element("#developer-delete-dialog-confirm") |> render_click()
      assert Repo.get!(Key, id)
    end

    view |> element("#api-key-#{named.id} [phx-click='delete_key']") |> render_click()
    assert has_element?(view, "#developer-delete-dialog", "Are you sure?")
    view |> element("#developer-delete-dialog-cancel") |> render_click()
    assert Repo.get!(Key, named.id)

    view |> element("#api-key-#{named.id} [phx-click='delete_key']") |> render_click()
    view |> element("#developer-delete-dialog-confirm") |> render_click()
    refute Repo.get(Key, named.id)
    refute has_element?(view, "#api-key-#{named.id}")
    assert Spaces.authenticate_api_key(named.key, named.secret) == :error
    assert {:ok, _, _} = Spaces.authenticate_api_key(ordinary.key, ordinary.secret)
    assert {:ok, _, _} = Spaces.authenticate_api_key(unnamed.key, unnamed.secret)

    view |> element("#api-key-#{unnamed.id} [phx-click='delete_key']") |> render_click()
    view |> element("#developer-delete-dialog-confirm") |> render_click()
    refute has_element?(view, "#api-key-#{unnamed.id}")
    assert has_element?(view, "#api-key-#{ordinary.id}")
    refute has_element?(view, "#settings-cli-connections")
  end

  defp connection(space, metadata) do
    {:ok, %{authorization: authorization, device_code: code}} =
      CliAuthorizations.create_authorization(client_metadata: metadata)

    {:ok, _} = CliAuthorizations.approve(authorization.user_code, space)
    {:ok, %{access_token: token}} = CliAuthorizations.exchange(code)
    [key_id, _secret] = token |> Base.decode64!() |> String.split(":", parts: 2)
    Spaces.get_key_by_identifier(key_id)
  end

  defp authenticated_conn(conn) do
    {:ok, user} =
      Accounts.create_user("cli-settings-#{System.unique_integer([:positive])}@example.com")

    token = Accounts.generate_user_login_token(user)
    {:ok, {user, login_token}} = Accounts.login_user(token)
    session = Accounts.generate_user_session_token(login_token, user)
    {init_test_session(conn, user_token: session), user.current_space_membership.space}
  end
end
