defmodule MaveCoreWeb.Live.Auth.IndexTest do
  use MaveCoreWeb.ConnCase, async: false

  alias MaveCore.Accounts

  import Phoenix.LiveViewTest
  import Swoosh.TestAssertions

  defmodule RejectingEmailChecker do
    @moduledoc false

    def valid?(_email), do: false
  end

  defp with_signup_country_options(options) do
    previous = Application.get_env(:mave_core, :signup_country_options, [])
    previous_policy = Application.get_env(:mave_core, :signup_policy)

    Application.put_env(:mave_core, :signup_country_options, options)

    Application.put_env(:mave_core, :signup_policy,
      terms_required: true,
      terms_url: "https://example.com/terms",
      privacy_url: "https://example.com/privacy",
      product_name: "Test Core",
      country_description: "Available in configured countries.",
      choose_country_message: "Select location of your company",
      unsupported_country_message:
        "We currently only support companies and organisations based in the EEA."
    )

    on_exit(fn ->
      Application.put_env(:mave_core, :signup_country_options, previous)
      restore_env(:signup_policy, previous_policy)
    end)
  end

  defp with_domain(domain) do
    previous = Application.get_env(:mave_core, :domain)
    Application.put_env(:mave_core, :domain, domain)
    on_exit(fn -> restore_env(:domain, previous) end)
  end

  for {label, setup_enabled, dev_routes, adapter, visible} <- [
        {"standalone development", true, true, Swoosh.Adapters.Local, true},
        {"without standalone setup", false, true, Swoosh.Adapters.Local, false},
        {"without development routes", true, false, Swoosh.Adapters.Local, false},
        {"without local mail", true, true, Swoosh.Adapters.Test, false}
      ] do
    test "local mailbox link #{label}", %{conn: conn} do
      config = [
        {:installation_setup, [enabled: unquote(setup_enabled)]},
        {:dev_routes, unquote(dev_routes)},
        {MaveCore.Mailer, [adapter: unquote(adapter)]}
      ]

      previous = Enum.map(config, fn {key, _} -> {key, Application.get_env(:mave_core, key)} end)
      on_exit(fn -> Enum.each(previous, fn {key, value} -> restore_env(key, value) end) end)
      Enum.each(config, fn {key, value} -> Application.put_env(:mave_core, key, value) end)
      assert {:ok, _user} = Accounts.create_user("mailbox-owner@example.com")

      {:ok, view, _html} = live(conn, "/login")

      view
      |> form("#login_form", %{"user" => %{"email" => "unknown@example.com"}})
      |> render_submit()

      assert has_element?(view, "#local-mailbox-help a[href='/dev/mailbox']") == unquote(visible)
    end
  end

  test "signup uses the legacy browser title", %{conn: conn} do
    {:ok, _view, html} = live(conn, "/signup")

    assert html =~ "<title>mave - video components</title>"
  end

  test "Google OAuth is hidden by default", %{conn: conn} do
    previous_enabled = Application.get_env(:mave_core, :google_oauth_enabled)
    Application.put_env(:mave_core, :google_oauth_enabled, false)

    on_exit(fn -> restore_env(:google_oauth_enabled, previous_enabled) end)

    {:ok, _view, html} = live(conn, "/login")

    refute html =~ "Continue with Google"
    refute html =~ ~s(href="/auth/google")
  end

  test "Google OAuth is shown only with opt-in and complete credentials", %{conn: conn} do
    previous_enabled = Application.get_env(:mave_core, :google_oauth_enabled)
    previous_oauth = Application.get_env(:ueberauth, Ueberauth.Strategy.Google.OAuth)

    Application.put_env(:mave_core, :google_oauth_enabled, true)

    Application.put_env(:ueberauth, Ueberauth.Strategy.Google.OAuth,
      client_id: "google-client",
      client_secret: "google-secret"
    )

    on_exit(fn ->
      restore_env(:google_oauth_enabled, previous_enabled)

      if is_nil(previous_oauth),
        do: Application.delete_env(:ueberauth, Ueberauth.Strategy.Google.OAuth),
        else: Application.put_env(:ueberauth, Ueberauth.Strategy.Google.OAuth, previous_oauth)
    end)

    {:ok, _view, html} = live(conn, "/login")

    assert html =~ "Continue with Google"
    assert html =~ ~s(href="/auth/google")
  end

  test "login confirmation repeats the submitted email without revealing account existence", %{
    conn: conn
  } do
    email = "possible-typo@example.com"
    {:ok, view, _html} = live(conn, "/login")

    html =
      view
      |> form("#login_form", %{"user" => %{"email" => email}})
      |> render_submit()

    assert html =~ "If #{email} is in our system"
    assert html =~ "Please check that the email address is correct."
    assert_no_email_sent()
  end

  test "signup shows validation error when email is empty", %{conn: conn} do
    {:ok, view, _html} = live(conn, "/signup")

    html =
      view
      |> form("#login_form", %{"signup" => %{"email" => ""}})
      |> render_submit()

    assert html =~ "Seems to be empty"
  end

  test "signup shows validation error when email domain cannot be verified", %{conn: conn} do
    previous = Application.get_env(:mave_core, :email_validation, [])

    Application.put_env(:mave_core, :email_validation, checker: RejectingEmailChecker)

    on_exit(fn -> Application.put_env(:mave_core, :email_validation, previous) end)

    email = "adsffas@dsf"
    {:ok, view, _html} = live(conn, "/signup")

    html =
      view
      |> form("#login_form", %{"signup" => %{"email" => email}})
      |> render_submit()

    assert html =~ "Doesn&#39;t seem right"
    refute Accounts.get_user_by_email(email)
    assert_no_email_sent()
  end

  test "signup shows terms error above checkbox when not accepted", %{conn: conn} do
    with_signup_country_options([])
    {:ok, view, _html} = live(conn, "/signup")

    assert has_element?(view, ~s|#terms[name="signup[terms]"][value="true"]:not([checked])|)

    assert has_element?(
             view,
             ~s(#terms-field input[type="hidden"][name="signup[terms]"][value="false"])
           )

    assert has_element?(
             view,
             ~s(label[for="terms"] a[href="https://example.com/terms"]),
             "Terms of Service"
           )

    assert has_element?(
             view,
             ~s(label[for="terms"] a[href="https://example.com/privacy"]),
             "Privacy Policy"
           )

    view
    |> form("#login_form", %{"signup" => %{"email" => "hello@example.com", "terms" => "false"}})
    |> render_submit()

    assert has_element?(view, "#terms-error", "Please accept the terms and conditions")
    assert has_element?(view, "#terms-error + #terms-field")
    refute has_element?(view, "#terms-field", "Please accept the terms and conditions")
    refute has_element?(view, "#terms[checked]")
    refute Accounts.get_user_by_email("hello@example.com")
    assert_no_email_sent()
  end

  test "signup keeps accepted terms checked when another field is invalid", %{conn: conn} do
    with_signup_country_options([])
    {:ok, view, _html} = live(conn, "/signup")

    view
    |> form("#login_form", %{"signup" => %{"email" => "", "terms" => "true"}})
    |> render_submit()

    assert has_element?(view, "#terms[checked]")
    refute has_element?(view, "#terms-error", "Please accept the terms and conditions")
    assert_no_email_sent()
  end

  test "signup accepts required terms without a country requirement", %{conn: conn} do
    with_signup_country_options([])
    email = "signup-terms-accepted@example.com"
    {:ok, view, _html} = live(conn, "/signup")

    view
    |> form("#login_form", %{"signup" => %{"email" => email, "terms" => "true"}})
    |> render_submit()

    assert_email_sent(subject: "Mave Core signup verification", to: email)
    assert %{} = Accounts.get_user_by_email(email)
  end

  test "signup requires a configured company country without storing it", %{conn: conn} do
    with_signup_country_options([{"Netherlands", "NL"}, {"United Kingdom", "GB"}])

    email = "signup-country-required@example.com"
    {:ok, view, html} = live(conn, "/signup")

    assert html =~ "Company location"
    assert html =~ "Netherlands"

    html =
      view
      |> form("#login_form", %{"signup" => %{"email" => email, "terms" => "true"}})
      |> render_submit()

    assert html =~ "Select location of your company"
    refute Accounts.get_user_by_email(email)
    assert_no_email_sent()
  end

  test "signup rejects countries outside the configured company country list", %{conn: conn} do
    with_signup_country_options([{"Netherlands", "NL"}])

    email = "signup-country-unsupported@example.com"
    {:ok, view, _html} = live(conn, "/signup")

    html =
      render_submit(view, "signup", %{
        "signup" => %{"email" => email, "terms" => "true", "country" => "US"}
      })

    assert html =~ "We currently only support companies and organisations based in the EEA"
    refute Accounts.get_user_by_email(email)
    assert_no_email_sent()
  end

  test "signup accepts a configured company country without persisting it", %{conn: conn} do
    with_signup_country_options([{"Netherlands", "NL"}])

    email = "signup-country-accepted@example.com"
    {:ok, view, _html} = live(conn, "/signup")

    view
    |> form("#login_form", %{
      "signup" => %{"email" => email, "terms" => "true", "country" => "NL"}
    })
    |> render_submit()

    assert_email_sent(subject: "Mave Core signup verification", to: email)
    assert %{} = Accounts.get_user_by_email(email)
  end

  test "signup sends signup verification email subject", %{conn: conn} do
    {:ok, view, _html} = live(conn, "/signup")

    refute has_element?(view, "#terms")

    view
    |> form("#login_form", %{
      "signup" => %{"email" => "signup-subject@example.com"}
    })
    |> render_submit()

    assert_email_sent(subject: "Mave Core signup verification", to: "signup-subject@example.com")
  end

  test "signup sends a login verification email when the account already exists", %{conn: conn} do
    email = "signup-existing@example.com"
    assert {:ok, _user} = Accounts.create_user(email)
    {:ok, view, _html} = live(conn, "/signup")

    view
    |> form("#login_form", %{
      "signup" => %{"email" => email}
    })
    |> render_submit()

    assert_email_sent(subject: "Mave Core login verification", to: email)
  end

  test "signup magic link uses the canonical domain instead of the request host", %{conn: conn} do
    with_domain("https://manage.example.test")
    conn = %{conn | host: "attacker.example"}
    {:ok, view, _html} = live(conn, "/signup")

    view
    |> form("#login_form", %{
      "signup" => %{"email" => "signup-domain@example.com"}
    })
    |> render_submit()

    assert_email_sent(fn email ->
      String.contains?(email.text_body, "https://manage.example.test/videos?token=") and
        String.contains?(
          email.html_body,
          "href=\"https://manage.example.test/videos?token="
        ) and
        not String.contains?(email.text_body, "attacker.example") and
        not String.contains?(email.html_body, "attacker.example")
    end)
  end

  test "login magic link uses the canonical domain instead of the request host", %{conn: conn} do
    with_domain("https://manage.example.test")
    email = "login-domain@example.com"
    assert {:ok, _user} = Accounts.create_user(email)

    conn = %{conn | host: "attacker.example"}
    {:ok, view, _html} = live(conn, "/login")

    view
    |> form("#login_form", %{"user" => %{"email" => email}})
    |> render_submit()

    assert_email_sent(fn sent_email ->
      String.contains?(sent_email.text_body, "https://manage.example.test/videos?token=") and
        String.contains?(
          sent_email.html_body,
          "href=\"https://manage.example.test/videos?token="
        ) and
        not String.contains?(sent_email.text_body, "attacker.example") and
        not String.contains?(sent_email.html_body, "attacker.example")
    end)
  end

  test "magic links fall back to the configured endpoint instead of the request host", %{
    conn: conn
  } do
    previous = Application.get_env(:mave_core, :domain)
    Application.delete_env(:mave_core, :domain)
    on_exit(fn -> restore_env(:domain, previous) end)

    conn = %{conn | host: "attacker.example"}
    {:ok, view, _html} = live(conn, "/signup")

    view
    |> form("#login_form", %{
      "signup" => %{"email" => "signup-endpoint-domain@example.com"}
    })
    |> render_submit()

    assert_email_sent(fn email ->
      String.contains?(email.text_body, "http://localhost:4000/videos?token=") and
        String.contains?(email.html_body, "href=\"http://localhost:4000/videos?token=") and
        not String.contains?(email.text_body, "attacker.example") and
        not String.contains?(email.html_body, "attacker.example")
    end)
  end

  test "signup magic link rejects scheme-relative return_to URLs", %{conn: conn} do
    with_domain("https://manage.example.test")
    conn = %{conn | host: "attacker.example"}
    {:ok, view, _html} = live(conn, "/signup?return_to=//evil.example/capture")

    view
    |> form("#login_form", %{
      "signup" => %{"email" => "signup-return-to@example.com"}
    })
    |> render_submit()

    assert_email_sent(fn email ->
      String.contains?(email.text_body, "https://manage.example.test/videos?token=") and
        String.contains?(
          email.html_body,
          "href=\"https://manage.example.test/videos?token="
        ) and
        not String.contains?(email.text_body, "attacker.example") and
        not String.contains?(email.html_body, "attacker.example") and
        not String.contains?(email.text_body, "evil.example") and
        not String.contains?(email.html_body, "evil.example")
    end)
  end

  test "signup keeps the user unconfirmed until the magic link is used", %{conn: conn} do
    email = "signup-confirmation@example.com"
    {:ok, view, _html} = live(conn, "/signup")

    view
    |> form("#login_form", %{
      "signup" => %{"email" => email}
    })
    |> render_submit()

    assert %{} = user = Accounts.get_user_by_email(email)
    assert is_nil(user.confirmed_at)
    assert is_nil(user.current_space_membership_id)
  end

  test "disabled public registration redirects signup and hides its login link", %{conn: conn} do
    previous = Application.get_env(:mave_core, :public_registration)
    Application.put_env(:mave_core, :public_registration, enabled: false, max_users: 100)
    on_exit(fn -> restore_env(:public_registration, previous) end)

    assert {:error, {:redirect, %{to: "/login"}}} = live(conn, "/signup")

    {:ok, _view, html} = live(conn, "/login")
    refute html =~ "Sign up here"
  end

  defp restore_env(key, nil), do: Application.delete_env(:mave_core, key)
  defp restore_env(key, value), do: Application.put_env(:mave_core, key, value)
end
