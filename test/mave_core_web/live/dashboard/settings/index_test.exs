defmodule MaveCoreWeb.Live.Dashboard.Settings.IndexTest do
  use MaveCoreWeb.ConnCase, async: false

  import Ecto.Query
  import Phoenix.LiveViewTest
  import Swoosh.TestAssertions

  alias MaveCore.{Accounts, Repo, Spaces}
  alias MaveCore.Spaces.{Domain, Key, Membership, MembershipInvite, Space, Webhook}
  alias MaveCoreWeb.DashboardRoutes

  test "/settings hides managed support when no host tab is configured", %{conn: conn} do
    previous_tabs = Application.get_env(:mave_core, :extra_settings_tabs)
    Application.put_env(:mave_core, :extra_settings_tabs, [])

    on_exit(fn ->
      if is_nil(previous_tabs),
        do: Application.delete_env(:mave_core, :extra_settings_tabs),
        else: Application.put_env(:mave_core, :extra_settings_tabs, previous_tabs)
    end)

    {conn, _space} = authenticated_conn(conn)
    {:ok, view, _html} = live(conn, "/settings")

    refute has_element?(view, "a[data-phx-link='patch'][href='/settings/support']", "Support")
  end

  test "/settings is DB-backed for domains and feature toggles", %{conn: conn} do
    {conn, space} = authenticated_conn(conn)

    assert {:ok, _domain} = Spaces.create_domain(space, %{"domain" => "example.com"})

    {:ok, view, html} = live(conn, "/settings")

    assert html =~ "example.com"
    assert html =~ "S3-compatible storage"
    assert html =~ "Configured storage profile"
    refute html =~ ~s(src="nil")
    refute html =~ ">nil<"
    refute html =~ "Scaleway"
    refute html =~ "Cloudflare"
    refute html =~ "Tigris"
    refute html =~ "contact support"

    view
    |> element("#settings-link-domain-button")
    |> render_click()

    _ =
      view
      |> form("#link-domain-form", domain: %{domain: "cdn.example.com"})
      |> render_submit()

    assert Repo.get_by(Domain, space_id: space.id, domain: "cdn.example.com")

    html = render(view)
    assert html =~ "Public sharing"
    refute html =~ "toggle_public_sharing"

    view
    |> element("[phx-click='toggle_hotlink_protection']")
    |> render_click()

    assert Repo.get!(MaveCore.Spaces.Space, space.id).hotlink_protection_enabled

    html = render(view)
    refute html =~ "Default upload flow"
    refute html =~ "space-processing-form"

    domain = Repo.get_by!(Domain, space_id: space.id, domain: "example.com")

    view
    |> element("[phx-click='unlink_domain'][phx-value-id='#{domain.id}']")
    |> render_click()

    stop_live_view(view)
    refute Repo.get(Domain, domain.id)
  end

  test "/settings accepts host-provided region cards without provider defaults", %{conn: conn} do
    previous_provider = Application.get_env(:mave_core, :dashboard_region_provider)

    Application.put_env(:mave_core, :dashboard_region_provider, {
      __MODULE__,
      :test_extra_regions_for_space
    })

    on_exit(fn ->
      if is_nil(previous_provider) do
        Application.delete_env(:mave_core, :dashboard_region_provider)
      else
        Application.put_env(:mave_core, :dashboard_region_provider, previous_provider)
      end
    end)

    {conn, space} = authenticated_conn(conn)
    {:ok, view, html} = live(conn, "/settings")

    refute html =~ "DEDICATED-EU"
    stop_live_view(view)

    space
    |> Ecto.Changeset.change(region: "custom")
    |> Repo.update!()

    {:ok, view, html} = live(conn, "/settings")

    assert html =~ "DEDICATED-EU"
    assert html =~ "current region"
    stop_live_view(view)
  end

  test "/settings keeps the space picker domain label in sync", %{conn: conn} do
    {conn, space} = authenticated_conn(conn)
    {:ok, view, html} = live(conn, "/settings")

    assert html =~ "No domain set"

    view
    |> element("#settings-link-domain-empty-button")
    |> render_click()

    _ =
      view
      |> form("#link-domain-form", domain: %{domain: "picker-sync.example.com"})
      |> render_submit()

    assert_eventually(fn ->
      render(element(view, "#sidebar")) =~ "picker-sync.example.com"
    end)

    domain = Repo.get_by!(Domain, space_id: space.id, domain: "picker-sync.example.com")

    view
    |> element("[phx-click='unlink_domain'][phx-value-id='#{domain.id}']")
    |> render_click()

    assert_eventually(fn ->
      sidebar = render(element(view, "#sidebar"))
      sidebar =~ "No domain set" and not (sidebar =~ "picker-sync.example.com")
    end)

    stop_live_view(view)
  end

  test "/settings shows domain validation errors", %{conn: conn} do
    {conn, _space} = authenticated_conn(conn)
    {:ok, view, _html} = live(conn, "/settings")

    view
    |> element("#settings-link-domain-empty-button")
    |> render_click()

    html =
      view
      |> form("#link-domain-form", domain: %{domain: "invalid"})
      |> render_submit()

    assert html =~ "This doesn&#39;t seem like a valid domain"
    stop_live_view(view)
  end

  test "/settings updates when another session links a domain", %{conn: conn} do
    {conn, space} = authenticated_conn(conn)
    {:ok, view, html} = live(conn, "/settings")

    refute html =~ "realtime-settings.example.com"

    assert {:ok, _domain} =
             Spaces.create_domain(space, %{"domain" => "realtime-settings.example.com"})

    assert_eventually(fn -> render(view) =~ "realtime-settings.example.com" end)
    stop_live_view(view)
  end

  test "/settings shows connect or disconnect for Google based on the linked account state", %{
    conn: conn
  } do
    previous_enabled = Application.get_env(:mave_core, :google_oauth_enabled)
    previous_oauth = Application.get_env(:ueberauth, Ueberauth.Strategy.Google.OAuth)

    Application.put_env(:mave_core, :google_oauth_enabled, true)

    Application.put_env(:ueberauth, Ueberauth.Strategy.Google.OAuth,
      client_id: "google-client",
      client_secret: "google-secret"
    )

    on_exit(fn ->
      restore_application_env(:mave_core, :google_oauth_enabled, previous_enabled)

      restore_application_env(
        :ueberauth,
        Ueberauth.Strategy.Google.OAuth,
        previous_oauth
      )
    end)

    {conn, _space} = authenticated_conn(conn)
    {:ok, _view, html} = live(conn, "/settings")

    assert html =~ "settings-google-connect-button"
    refute html =~ "settings-google-disconnect-button"

    current_user = Accounts.get_user_by_session_token(get_session(conn, :user_token))
    assert {:ok, pending_user} = Accounts.mark_google_link_pending(current_user)

    assert {:ok, _user} =
             Accounts.link_google_account(pending_user, %{
               uid: "settings-google-uid",
               email: current_user.email
             })

    {:ok, _view, linked_html} = live(conn, "/settings")
    assert linked_html =~ "settings-google-disconnect-button"
    refute linked_html =~ "settings-google-connect-button"
  end

  test "/settings deletes the confirmed account and current space", %{conn: conn} do
    {conn, space} = authenticated_conn(conn)
    user = Accounts.get_user_by_session_token(get_session(conn, :user_token))

    {:ok, view, _html} = live(conn, "/settings")

    view
    |> element("#settings-delete-account-button")
    |> render_click()

    refute render(view) =~ "active subscription"

    view
    |> element("#delete_confirmation")
    |> render_keyup(%{"value" => "DELETE"})

    view
    |> element("#delete-account-submit")
    |> render_click()

    assert {:error, {:redirect, %{to: "/login"}}} =
             view
             |> element("#confirm-delete-account-dialog-confirm")
             |> render_click()

    anonymized_email = "deleted##{user.id}"
    assert Repo.get!(MaveCore.Accounts.User, user.id).email == anonymized_email
    assert Repo.get!(Space, space.id).deleted_at
    refute Accounts.get_user_by_email(user.email)
  end

  test "/settings shows delete account eligibility errors in the first modal", %{conn: conn} do
    {conn, space} = authenticated_conn(conn)
    user = Accounts.get_user_by_session_token(get_session(conn, :user_token))

    assert {:ok, _updated_user} = Accounts.create_space_for_user(user)

    {:ok, view, _html} = live(conn, "/settings")

    view
    |> element("#settings-delete-account-button")
    |> render_click()

    view
    |> element("#delete_confirmation")
    |> render_keyup(%{"value" => "DELETE"})

    html =
      view
      |> element("#delete-account-submit")
      |> render_click()

    assert html =~ "delete-account-error"
    assert html =~ "You can only delete your account when you own a single space."
    assert html =~ "Delete account"
    stop_live_view(view)
    assert Repo.get!(Space, space.id).deleted_at == nil
    assert Accounts.get_user_by_email(user.email)
  end

  test "/:space_id/settings opens the same settings page for a direct space url", %{conn: conn} do
    {conn, space} = authenticated_conn(conn)

    assert {:ok, _domain} =
             Spaces.create_domain(space, %{"domain" => "scoped-settings.example.com"})

    {:ok, _view, html} = live(conn, DashboardRoutes.settings_path(space))

    assert html =~ "scoped-settings.example.com"
  end

  test "/settings/developer is DB-backed for key and webhook actions", %{conn: conn} do
    {conn, space} = authenticated_conn(conn)

    {:ok, view, _html} = live(conn, "/settings/developer")

    view
    |> element("#settings-generate-key-empty-button")
    |> render_click()

    _ =
      view
      |> form("#api-key-form",
        api_key: %{description: "Website uploader", access_level: "read_only"}
      )
      |> render_submit()

    assert Repo.aggregate(from(k in Key, where: k.space_id == ^space.id), :count, :id) == 1
    created_key = Repo.get_by!(Key, space_id: space.id)
    assert created_key.description == "Website uploader"
    assert created_key.access_level == :read_only

    view
    |> element("#settings-create-webhook-empty-button")
    |> render_click()

    _ =
      view
      |> form("#create-webhook-form",
        webhook: %{url: "https://example.com/webhook", description: "Main"}
      )
      |> render_submit()

    webhook = Repo.get_by!(Webhook, space_id: space.id, url: "https://example.com/webhook")
    assert webhook.enabled

    masked_webhook_secret =
      "#{String.slice(webhook.secret, 0, 7)}••••••••••••#{String.slice(webhook.secret, -5, 5)}"

    assert has_element?(
             view,
             "#webhook-secret-#{webhook.id}",
             masked_webhook_secret
           )

    refute has_element?(
             view,
             "#webhook-secret-#{webhook.id} .select-text",
             webhook.secret
           )

    assert has_element?(
             view,
             "#webhook-secret-#{webhook.id}-toggle[aria-label='Reveal Webhook secret']"
           )

    view
    |> element("#webhook-secret-#{webhook.id}-toggle")
    |> render_click()

    assert has_element?(
             view,
             "#webhook-secret-#{webhook.id} .select-text",
             webhook.secret
           )

    assert {:ok, [_delivery]} =
             Spaces.enqueue_webhook_event(
               space,
               :video_uploaded,
               %{"embed_hash" => "abc123"},
               %{enqueue: false}
             )

    view
    |> element("#settings-generate-key-button")
    |> render_click()

    _ =
      view
      |> form("#api-key-form", api_key: %{description: "", access_level: "read_write"})
      |> render_submit()

    html = render(view)
    refute html =~ "Recent deliveries"
    refute html =~ "no deliveries yet"

    view
    |> element("[phx-click='toggle_webhook'][phx-value-id='#{webhook.id}']")
    |> render_click()

    refute Repo.get!(Webhook, webhook.id).enabled

    key = Repo.one!(from(k in Key, where: k.space_id == ^space.id, limit: 1))

    view
    |> element("[phx-click='delete_key'][phx-value-id='#{key.id}']")
    |> render_click()

    view
    |> element("#developer-delete-dialog-confirm")
    |> render_click()

    refute Repo.get(Key, key.id)

    view
    |> element("[phx-click='delete_webhook'][phx-value-id='#{webhook.id}']")
    |> render_click()

    view
    |> element("#developer-delete-dialog-confirm")
    |> render_click()

    stop_live_view(view)
    refute Repo.get(Webhook, webhook.id)
  end

  test "/settings/team is DB-backed for member add/remove actions", %{conn: conn} do
    {conn, space} = authenticated_conn(conn)

    member_email = "team-view-#{System.unique_integer([:positive])}@example.com"
    {:ok, member_user} = Accounts.create_user(member_email)

    {:ok, view, _html} = live(conn, "/settings/team")

    view
    |> element("#settings-add-member-button")
    |> render_click()

    _ =
      view
      |> form("#add-member-form", member: %{email: member_user.email})
      |> render_submit()

    membership =
      Repo.one!(
        from(m in Membership,
          join: i in assoc(m, :invite),
          where: m.space_id == ^space.id and i.user_id == ^member_user.id,
          preload: [invite: i]
        )
      )

    assert render(view) =~ String.downcase(member_user.email)
    assert is_nil(membership.user_id)
    assert membership.invite.accepted_at == nil

    view
    |> element("[phx-click='remove_member'][phx-value-id='#{membership.id}']")
    |> render_click()

    stop_live_view(view)
    refute Repo.get(Membership, membership.id)
  end

  test "/settings/team lets accepted members manage non-owner members", %{conn: conn} do
    {owner_conn, space} = authenticated_conn(conn)
    owner = Accounts.get_user_by_session_token(get_session(owner_conn, :user_token))

    invitee_email = "team-manager-#{System.unique_integer([:positive])}@example.com"
    other_email = "team-managed-#{System.unique_integer([:positive])}@example.com"
    {:ok, invitee} = Accounts.create_invited_user(invitee_email)
    {:ok, other_user} = Accounts.create_user(other_email)

    assert {:ok, invitee_membership} =
             Spaces.create_membership_invite(space, owner, invitee.email)

    assert {:ok, accepted_membership} =
             Spaces.accept_membership_invite(invitee_membership, invitee)

    assert {:ok, invitee} = Accounts.set_current_space_membership(invitee, accepted_membership)

    conn = authenticated_conn_for_user(conn, invitee)
    {:ok, view, _html} = live(conn, "/settings/team")

    owner_membership =
      Repo.one!(
        from(m in Membership,
          where: m.space_id == ^space.id and m.user_id == ^owner.id
        )
      )

    refute has_element?(
             view,
             "[phx-click='remove_member'][phx-value-id='#{owner_membership.id}']"
           )

    assert has_element?(view, "#settings-add-member-button")

    view
    |> element("#settings-add-member-button")
    |> render_click()

    _ =
      view
      |> form("#add-member-form", member: %{email: other_user.email})
      |> render_submit()

    managed_membership =
      Repo.one!(
        from(m in Membership,
          join: i in assoc(m, :invite),
          where: m.space_id == ^space.id and i.user_id == ^other_user.id,
          preload: [invite: i]
        )
      )

    assert render(view) =~ String.downcase(other_user.email)

    view
    |> element("[phx-click='remove_member'][phx-value-id='#{managed_membership.id}']")
    |> render_click()

    stop_live_view(view)
    refute Repo.get(Membership, managed_membership.id)
  end

  test "/settings/team lets accepted members leave the team", %{conn: conn} do
    {owner_conn, space} = authenticated_conn(conn)
    owner = Accounts.get_user_by_session_token(get_session(owner_conn, :user_token))

    invitee_email = "team-leaver-#{System.unique_integer([:positive])}@example.com"
    {:ok, invitee} = Accounts.create_invited_user(invitee_email)

    assert {:ok, invitee_membership} =
             Spaces.create_membership_invite(space, owner, invitee.email)

    assert {:ok, accepted_membership} =
             Spaces.accept_membership_invite(invitee_membership, invitee)

    assert {:ok, invitee} = Accounts.set_current_space_membership(invitee, accepted_membership)

    conn = authenticated_conn_for_user(conn, invitee)
    {:ok, view, _html} = live(conn, "/settings/team")

    assert has_element?(
             view,
             "[phx-click='remove_member'][phx-value-id='#{accepted_membership.id}']"
           )

    view
    |> element("[phx-click='remove_member'][phx-value-id='#{accepted_membership.id}']")
    |> render_click()

    refute Repo.get(Membership, accepted_membership.id)

    updated_invitee = Accounts.get_user_by_email(invitee_email)
    assert updated_invitee.current_space_membership_id
    assert updated_invitee.current_space_membership_id != accepted_membership.id
    assert_redirect(view, DashboardRoutes.signed_in_path(updated_invitee))
    stop_live_view(view)
  end

  test "/settings/team updates when another session invites a member", %{conn: conn} do
    {conn, space} = authenticated_conn(conn)
    current_user = Accounts.get_user_by_session_token(get_session(conn, :user_token))
    member_email = "team-realtime-#{System.unique_integer([:positive])}@example.com"
    {:ok, member_user} = Accounts.create_user(member_email)

    {:ok, view, html} = live(conn, "/settings/team")

    refute html =~ String.downcase(member_user.email)

    assert {:ok, _membership} =
             Spaces.create_membership_invite(space, current_user, member_user.email)

    assert_eventually(fn -> render(view) =~ String.downcase(member_user.email) end)
    stop_live_view(view)
  end

  test "/settings/developer masks, reveals, and describes an existing API key", %{conn: conn} do
    {conn, space} = authenticated_conn(conn)
    assert {:ok, internal_key} = Spaces.ensure_internal_key(space, :dashboard_uploads)
    {:ok, view, html} = live(conn, "/settings/developer")

    assert html =~ "no keys yet"
    refute html =~ "Dashboard uploads"
    refute has_element?(view, "#api-key-#{internal_key.id}")

    assert {:ok, key} = Spaces.create_key(space)
    display_key = Spaces.display_api_key(key.key, key.secret)

    masked_key =
      "#{String.slice(display_key, 0, 7)}••••••••••••#{String.slice(display_key, -5, 5)}"

    assert_eventually(fn -> render(view) =~ "No description" end)
    assert has_element?(view, "#key-#{key.id}", masked_key)

    refute has_element?(
             view,
             "#key-#{key.id} .select-text",
             display_key
           )

    assert has_element?(
             view,
             "#key-#{key.id}-toggle[aria-label='Reveal API key'][aria-pressed='false']"
           )

    assert has_element?(
             view,
             "#api-key-#{key.id} button[aria-label='Copy to clipboard']"
           )

    view
    |> element("#key-#{key.id}-toggle")
    |> render_click()

    assert has_element?(
             view,
             "#key-#{key.id} .select-text",
             display_key
           )

    assert has_element?(
             view,
             "#key-#{key.id}-toggle[aria-label='Hide API key'][aria-pressed='true']"
           )

    assert has_element?(
             view,
             "#api-key-#{key.id} button[aria-label='Copy to clipboard']"
           )

    view
    |> element("#edit-key-#{key.id}")
    |> render_click()

    _ =
      view
      |> form("#api-key-form",
        api_key: %{description: "Legacy collection", access_level: "read_only"}
      )
      |> render_submit()

    updated_key = Repo.get!(Key, key.id)
    assert updated_key.description == "Legacy collection"
    assert updated_key.access_level == :read_only

    assert has_element?(
             view,
             "#api-key-#{key.id} [title='Legacy collection']",
             "Legacy collection"
           )

    assert has_element?(
             view,
             "#key-access-level-#{key.id}[aria-label='API key access level: read only']",
             "read only"
           )

    stop_live_view(view)
  end

  test "/settings/developer can change an API key access level in both directions", %{
    conn: conn
  } do
    {conn, space} = authenticated_conn(conn)
    assert {:ok, key} = Spaces.create_key(space)
    {:ok, view, _html} = live(conn, "/settings/developer")

    assert has_element?(
             view,
             "#key-access-level-#{key.id}[aria-label='API key access level: read/write']",
             "read/write"
           )

    view
    |> element("#edit-key-#{key.id}")
    |> render_click()

    assert has_element?(
             view,
             "#api_key_access_level option[value='read_write'][selected]"
           )

    _ =
      view
      |> form("#api-key-form",
        api_key: %{description: "", access_level: "read_only"}
      )
      |> render_submit()

    assert Repo.get!(Key, key.id).access_level == :read_only

    assert has_element?(
             view,
             "#key-access-level-#{key.id}[aria-label='API key access level: read only']",
             "read only"
           )

    view
    |> element("#edit-key-#{key.id}")
    |> render_click()

    assert has_element?(
             view,
             "#api_key_access_level option[value='read_only'][selected]"
           )

    _ =
      view
      |> form("#api-key-form",
        api_key: %{description: "", access_level: "read_write"}
      )
      |> render_submit()

    assert Repo.get!(Key, key.id).access_level == :read_write

    assert has_element?(
             view,
             "#key-access-level-#{key.id}[aria-label='API key access level: read/write']",
             "read/write"
           )

    stop_live_view(view)
  end

  test "/settings/team invites email that has no account yet", %{conn: conn} do
    {conn, space} = authenticated_conn(conn)
    inviter = Accounts.get_user_by_session_token(get_session(conn, :user_token))
    invited_email = "team-invite-#{System.unique_integer([:positive])}@example.com"

    {:ok, view, _html} = live(conn, "/settings/team")

    view
    |> element("#settings-add-member-button")
    |> render_click()

    _ =
      view
      |> form("#add-member-form", member: %{email: invited_email})
      |> render_submit()

    invited_user = Accounts.get_user_by_email(invited_email)
    assert invited_user

    membership =
      Repo.one!(
        from(m in Membership,
          join: i in assoc(m, :invite),
          where: m.space_id == ^space.id and i.user_id == ^invited_user.id,
          preload: [invite: i]
        )
      )

    assert is_nil(membership.user_id)
    assert membership.invite.accepted_at == nil
    assert Repo.get(MembershipInvite, membership.invite.id)

    assert render(view) =~ invited_email
    stop_live_view(view)

    assert_email_sent(fn email ->
      email.subject == "Mave Core invite from #{inviter.email}" and
        Enum.any?(email.to, fn {_name, address} -> address == invited_email end) and
        String.contains?(email.text_body, "/space?invite=#{membership.invite.id}&token=") and
        String.contains?(
          email.text_body,
          "You have been invited to Mave Core by #{inviter.email}"
        ) and
        String.contains?(
          email.html_body,
          "You have been invited to Mave Core by #{inviter.email}"
        ) and
        not String.contains?(email.text_body, "your mave space") and
        not String.contains?(email.html_body, "your mave space") and
        not String.contains?(email.html_body, "invited to space") and
        not String.contains?(email.text_body, space.hash) and
        not String.contains?(email.html_body, space.hash)
    end)
  end

  test "/settings/team invite email uses the space domain when present", %{conn: conn} do
    {conn, space} = authenticated_conn(conn)
    inviter = Accounts.get_user_by_session_token(get_session(conn, :user_token))
    invited_email = "team-invite-domain-#{System.unique_integer([:positive])}@example.com"

    assert {:ok, _domain} =
             Spaces.create_domain(space, %{"domain" => "video.example.com"})

    {:ok, view, _html} = live(conn, "/settings/team")

    view
    |> element("#settings-add-member-button")
    |> render_click()

    _ =
      view
      |> form("#add-member-form", member: %{email: invited_email})
      |> render_submit()

    stop_live_view(view)
    invited_user = Accounts.get_user_by_email(invited_email)

    membership =
      Repo.one!(
        from(m in Membership,
          join: i in assoc(m, :invite),
          where: m.space_id == ^space.id and i.user_id == ^invited_user.id,
          preload: [invite: i]
        )
      )

    assert_email_sent(fn email ->
      email.subject == "Mave Core invite from #{inviter.email}" and
        Enum.any?(email.to, fn {_name, address} -> address == invited_email end) and
        String.contains?(email.text_body, "/space?invite=#{membership.invite.id}&token=") and
        String.contains?(
          email.text_body,
          "You have been invited to Mave Core by #{inviter.email}"
        ) and
        String.contains?(
          email.html_body,
          "You have been invited to Mave Core by #{inviter.email}"
        ) and
        String.contains?(email.text_body, "video.example.com") and
        String.contains?(email.html_body, "video.example.com") and
        not String.contains?(email.html_body, "invited to space") and
        not String.contains?(email.text_body, space.hash) and
        not String.contains?(email.html_body, space.hash)
    end)
  end

  test "/settings/team shows the managing space instead of copied manager users", %{conn: conn} do
    {conn, owner_space} = authenticated_conn(conn)
    current_user = Accounts.get_user_by_session_token(get_session(conn, :user_token))

    assert {:ok, _domain} =
             Spaces.create_domain(owner_space, %{"domain" => "manager-space.example.com"})

    child_space =
      %Space{}
      |> Space.create_changeset(%{
        "hash" => "child#{System.unique_integer([:positive])}",
        "region" => "eu"
      })
      |> Repo.insert!()

    %Membership{}
    |> Membership.create_changeset(%{
      owner_space_id: owner_space.id,
      space_id: child_space.id,
      role: "owner"
    })
    |> Repo.insert!()

    member_email = "managed-team-child-#{System.unique_integer([:positive])}@example.com"
    {:ok, member_user} = Accounts.create_user(member_email)

    {:ok, _membership} =
      Spaces.add_member_by_email(child_space, member_user.email, %{role: "member"})

    assert {:ok, _switched_user} = Accounts.set_current_space_by_id(current_user, child_space.id)

    {:ok, _view, html} = live(conn, "/settings/team")

    assert html =~ "manager-space.example.com"
    assert html =~ String.downcase(member_user.email)
  end

  defp authenticated_conn(conn) do
    email = "settings-index-#{System.unique_integer([:positive])}@example.com"
    {:ok, user} = Accounts.create_user(email)
    conn = authenticated_conn_for_user(conn, user)

    logged_in_user = Accounts.get_user_by_session_token(get_session(conn, :user_token))

    {conn, logged_in_user.current_space_membership.space}
  end

  defp authenticated_conn_for_user(conn, user) do
    login_token = Accounts.generate_user_login_token(user)
    {:ok, {logged_in_user, persisted_login_token}} = Accounts.login_user(login_token)
    session_token = Accounts.generate_user_session_token(persisted_login_token, logged_in_user)

    conn
    |> with_manage_host()
    |> init_test_session(user_token: session_token)
  end

  defp with_manage_host(conn) do
    case System.get_env("MAVE_MANAGE_HOST") do
      host when is_binary(host) and host != "" -> %{conn | host: host}
      _ -> conn
    end
  end

  def test_extra_regions_for_space(%Space{region: "custom"}) do
    [
      %{
        id: "custom",
        name: "DEDICATED-EU",
        location: "Hosted in Europe"
      }
    ]
  end

  def test_extra_regions_for_space(_space), do: []

  defp assert_eventually(fun, attempts \\ 20)

  defp assert_eventually(fun, attempts) when attempts > 0 do
    if fun.() do
      assert true
    else
      Process.sleep(25)
      assert_eventually(fun, attempts - 1)
    end
  end

  defp assert_eventually(_fun, 0), do: flunk("condition did not become true in time")

  defp restore_application_env(app, key, nil), do: Application.delete_env(app, key)
  defp restore_application_env(app, key, value), do: Application.put_env(app, key, value)
end
