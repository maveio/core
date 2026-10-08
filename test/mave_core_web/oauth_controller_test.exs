defmodule MaveCoreWeb.OAuthControllerTest do
  use MaveCoreWeb.ConnCase, async: false

  alias MaveCore.Accounts
  alias MaveCoreWeb.DashboardRoutes
  alias MaveCoreWeb.OAuthController

  @secret_key_base String.duplicate("a", 64)

  test "request is unavailable unless Google OAuth is explicitly enabled and configured", %{
    conn: conn
  } do
    previous_enabled = Application.get_env(:mave_core, :google_oauth_enabled)
    previous = Application.get_env(:ueberauth, Ueberauth.Strategy.Google.OAuth, [])

    Application.put_env(:mave_core, :google_oauth_enabled, true)

    Application.put_env(:ueberauth, Ueberauth.Strategy.Google.OAuth,
      client_id: nil,
      client_secret: nil
    )

    on_exit(fn ->
      if is_nil(previous_enabled),
        do: Application.delete_env(:mave_core, :google_oauth_enabled),
        else: Application.put_env(:mave_core, :google_oauth_enabled, previous_enabled)

      Application.put_env(:ueberauth, Ueberauth.Strategy.Google.OAuth, previous)
    end)

    conn = get(conn, "/auth/google")
    assert response(conn, 404) == "Not found"
  end

  test "callback auto-creates a user for a verified Google email", %{conn: conn} do
    conn =
      conn
      |> auth_callback_conn()
      |> assign(
        :ueberauth_auth,
        google_auth("google-create-uid", "google-create@example.com", true)
      )
      |> OAuthController.callback(%{"provider" => "google"})

    assert redirected_to(conn) ==
             DashboardRoutes.signed_in_path(
               Accounts.get_user_by_email("google-create@example.com")
             )

    assert get_session(conn, :user_token)
    assert %{} = Accounts.get_user_by_email("google-create@example.com")
  end

  test "callback auto-links an existing email without google_uid", %{conn: conn} do
    email = "google-autolink-callback@example.com"
    uid = "google-autolink-callback-uid"

    assert {:ok, _user} = Accounts.create_user(email)

    conn =
      conn
      |> auth_callback_conn()
      |> assign(:ueberauth_auth, google_auth(uid, email, true))
      |> OAuthController.callback(%{"provider" => "google"})

    assert redirected_to(conn) ==
             DashboardRoutes.signed_in_path(Accounts.get_user_by_email(email))

    assert %{} = linked_user = Accounts.get_user_by_email(email)
    assert linked_user.google_uid == uid
  end

  test "callback signs in an existing google_uid user", %{conn: conn} do
    email = "google-existing-callback@example.com"
    uid = "google-existing-callback-uid"

    assert {:ok, _user} =
             Accounts.create_user(email, %{google_uid: uid, skip_email_validation: true})

    conn =
      conn
      |> auth_callback_conn()
      |> assign(:ueberauth_auth, google_auth(uid, email, true))
      |> OAuthController.callback(%{"provider" => "google"})

    assert redirected_to(conn) ==
             DashboardRoutes.signed_in_path(Accounts.get_user_by_email(email))

    assert get_session(conn, :user_token)
  end

  test "callback rejects unverified emails", %{conn: conn} do
    conn =
      conn
      |> auth_callback_conn()
      |> assign(
        :ueberauth_auth,
        google_auth("google-unverified-uid", "google-unverified@example.com", false)
      )
      |> OAuthController.callback(%{"provider" => "google"})

    assert redirected_to(conn) == "/login?error=email"
  end

  test "callback rejects email mismatch when email already belongs to another google uid", %{
    conn: conn
  } do
    email = "google-no-match@example.com"

    assert {:ok, _user} =
             Accounts.create_user(email, %{
               google_uid: "existing-google-uid",
               skip_email_validation: true
             })

    conn =
      conn
      |> auth_callback_conn()
      |> assign(:ueberauth_auth, google_auth("new-google-uid", email, true))
      |> OAuthController.callback(%{"provider" => "google"})

    assert redirected_to(conn) == "/login?error=no_match"
  end

  test "callback links google to the current signed-in user when pending and email matches", %{
    conn: conn
  } do
    email = "google-link-current@example.com"
    uid = "google-link-current-uid"

    assert {:ok, user} = Accounts.create_user(email)
    assert {:ok, pending_user} = Accounts.mark_google_link_pending(user)

    conn =
      conn
      |> auth_callback_conn()
      |> assign(:current_user, pending_user)
      |> assign(:ueberauth_auth, google_auth(uid, email, true))
      |> OAuthController.callback(%{"provider" => "google"})

    assert redirected_to(conn) == DashboardRoutes.settings_path(pending_user)
    assert Phoenix.Flash.get(conn.assigns.flash, :info) == "Google account connected."

    assert %{} = linked_user = Accounts.get_user_by_email(email)
    assert linked_user.google_uid == uid
    assert is_nil(linked_user.google_uid_pending_since)
  end

  test "callback rejects google linking when the email does not match the current user", %{
    conn: conn
  } do
    assert {:ok, user} = Accounts.create_user("google-link-mismatch@example.com")
    assert {:ok, pending_user} = Accounts.mark_google_link_pending(user)

    conn =
      conn
      |> auth_callback_conn()
      |> assign(:current_user, pending_user)
      |> assign(
        :ueberauth_auth,
        google_auth("google-link-mismatch-uid", "other@example.com", true)
      )
      |> OAuthController.callback(%{"provider" => "google"})

    assert redirected_to(conn) == DashboardRoutes.settings_path(pending_user)

    assert Phoenix.Flash.get(conn.assigns.flash, :error) ==
             "Please connect a Google account with the same email address."
  end

  defp google_auth(uid, email, verified?) do
    %{
      provider: :google,
      uid: uid,
      info: %{email: email},
      extra: %{raw_info: %{user: %{"email_verified" => verified?}}}
    }
  end

  defp auth_callback_conn(conn) do
    conn
    |> init_test_session(%{})
    |> Phoenix.Controller.fetch_flash([])
    |> Map.put(:secret_key_base, @secret_key_base)
  end
end
