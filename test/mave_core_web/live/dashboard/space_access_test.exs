defmodule MaveCoreWeb.Live.Dashboard.SpaceAccessTest do
  use MaveCoreWeb.ConnCase, async: false

  import Phoenix.LiveViewTest

  alias MaveCore.{Accounts, Embeds, Repo, Spaces}
  alias MaveCore.Embeds.Embed
  alias MaveCore.Spaces.{Domain, Key, Membership, Space}
  alias MaveCoreWeb.SpaceLiveAuth
  alias Phoenix.LiveView.{Lifecycle, Socket}

  setup %{conn: conn} do
    suffix = System.unique_integer([:positive])
    {:ok, owner} = Accounts.create_user("access-owner-#{suffix}@example.com")
    {:ok, member} = Accounts.create_user("access-member-#{suffix}@example.com")
    space = owner.current_space_membership.space
    {:ok, invite} = Spaces.create_membership_invite(space, owner, member.email)
    {:ok, membership} = Spaces.accept_membership_invite(invite, member)
    {:ok, member} = Accounts.set_current_space_membership(member, membership)
    login_token = Accounts.generate_user_login_token(member)
    {:ok, {logged_in_member, persisted_token}} = Accounts.login_user(login_token)
    token = Accounts.generate_user_session_token(persisted_token, logged_in_member)
    conn = init_test_session(conn, %{user_token: token})

    %{conn: conn, member: member, membership: membership, space: space}
  end

  test "a component cannot mint a key after silent membership removal", context do
    %{conn: conn, space: space, membership: membership} = context
    {:ok, view, _} = live(conn, "/settings/developer")
    view |> element("[phx-click='open_modal'][phx-value-modal='api_key']") |> render_click()
    # No PubSub notification: the action itself must check current authority.
    Repo.delete!(membership)

    view
    |> form("#api-key-form", api_key: %{description: "revoked-key", access_level: "read_write"})
    |> render_submit()

    assert_redirect(view, "/videos")
    refute Repo.get_by(Key, space_id: space.id, description: "revoked-key")
  end

  test "a component cannot unlink a domain after silent membership removal", context do
    %{conn: conn, space: space, membership: membership} = context
    {:ok, domain} = Spaces.create_domain(space, %{"domain" => "access.example.com"})
    {:ok, view, _} = live(conn, "/settings")
    Repo.delete!(membership)

    view |> element("[phx-click='unlink_domain'][phx-value-id='#{domain.id}']") |> render_click()
    assert_redirect(view, "/videos")
    assert Repo.get(Domain, domain.id)
  end

  test "parent events cannot create videos with stale access", context do
    %{conn: conn, space: space, membership: membership} = context
    {:ok, view, _} = live(conn, "/videos")
    before_count = Repo.aggregate(Embed, :count)
    Repo.delete!(membership)

    render_click(view, "create_video", %{})
    assert_redirect(view, "/videos")
    assert Repo.aggregate(Embed, :count) == before_count
    assert Embeds.list_root_items(space).videos == []
  end

  test "standalone access ignores deployment grants without a configured provider", context do
    %{member: member, space: space, membership: membership} = context
    previous = Application.get_env(:mave_core, :dashboard_space_access_provider)
    Application.delete_env(:mave_core, :dashboard_space_access_provider)

    on_exit(fn ->
      if previous do
        Application.put_env(:mave_core, :dashboard_space_access_provider, previous)
      else
        Application.delete_env(:mave_core, :dashboard_space_access_provider)
      end
    end)

    grant = %{space_id: space.id, user_token: "untrusted"}
    assert SpaceLiveAuth.can_access_space?(member, space, grant)
    Repo.delete!(membership)
    refute SpaceLiveAuth.can_access_space?(member, space, grant)
    refute SpaceLiveAuth.can_access_space?(%{member | email: "admin@mave.io"}, space, grant)
  end

  test "an async result cannot deliver space data after silent membership removal", context do
    %{member: member, space: space, membership: membership} = context

    socket =
      %Socket{private: %{lifecycle: %Lifecycle{}}}
      |> Phoenix.Component.assign(current_user: member, current_space: space)
      |> SpaceLiveAuth.attach_component()

    result = {:ok, %{private_space_data: "completed while access was being revoked"}}
    assert {:cont, ^socket} = Lifecycle.handle_async(:fetch_stats, result, socket)

    Repo.delete!(membership)
    assert {:halt, rejected} = Lifecycle.handle_async(:fetch_stats, result, socket)
    assert {:redirect, %{to: "/videos"}} = rejected.redirected
  end

  test "revoking parent membership disconnects a managed child dashboard", context do
    %{conn: conn, member: member, membership: membership, space: space} = context

    child =
      Repo.insert!(%Space{
        hash: "access-child-#{System.unique_integer([:positive])}",
        region: "default"
      })

    Repo.insert!(
      Membership.create_changeset(%Membership{}, %{
        owner_space_id: space.id,
        space_id: child.id,
        role: "owner"
      })
    )

    assert Accounts.can_access_space?(member, child)
    {:ok, _} = Accounts.set_current_space_by_id(member, child.id)
    {:ok, view, _} = live(conn, "/settings/developer")

    assert {:ok, _} = Spaces.remove_member(space, membership.id)
    assert_redirect(view, "/videos")
    refute Accounts.can_access_space?(member, child)
    assert Accounts.list_user_spaces(member) != []
  end
end
