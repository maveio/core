defmodule MaveCoreWeb.Live.Dashboard.Settings.AudioDescriptionSettingTest do
  use MaveCoreWeb.ConnCase, async: false

  import Phoenix.LiveViewTest

  alias MaveCore.Accounts
  alias MaveCore.Repo
  alias MaveCore.Spaces.Space

  defmodule PaidOnly do
    @behaviour MaveCore.UsageLimits

    def can_create_video_embed?(_space), do: :ok
    def can_add_space_member?(_space, _role), do: :ok
    def can_use_audio_description?(_space), do: {:error, :paid_plan_required}

    def restriction_copy(:audio_description, :paid_plan_required),
      do: %{notice: "Available on paid plans", error: "Upgrade to use audio description."}

    def restriction_copy(_operation, _reason), do: %{}
  end

  setup do
    old_backend = Application.get_env(:mave_core, :usage_limits_backend)

    on_exit(fn ->
      if old_backend,
        do: Application.put_env(:mave_core, :usage_limits_backend, old_backend),
        else: Application.delete_env(:mave_core, :usage_limits_backend)
    end)

    :ok
  end

  test "toggles audio description for the space", %{conn: conn} do
    {conn, space} = authenticated_conn(conn)
    {:ok, view, _html} = live(conn, "/settings")

    assert has_element?(view, "#audio-description-feature")
    refute has_element?(view, "#audio-description-notice")

    view |> element("#audio-description-toggle") |> render_click()
    assert Repo.get!(Space, space.id).audio_description_enabled

    view |> element("#audio-description-toggle") |> render_click()
    refute Repo.get!(Space, space.id).audio_description_enabled
  end

  test "shows the host's notice and keeps the toggle off when not allowed", %{conn: conn} do
    {conn, space} = authenticated_conn(conn)
    Application.put_env(:mave_core, :usage_limits_backend, PaidOnly)
    {:ok, view, html} = live(conn, "/settings")

    assert html =~ "Available on paid plans"
    assert has_element?(view, "#audio-description-toggle.pointer-events-none")
    refute Repo.get!(Space, space.id).audio_description_enabled
  end

  defp authenticated_conn(conn) do
    email = "ad-settings-#{System.unique_integer([:positive])}@example.com"
    {:ok, user} = Accounts.create_user(email)
    login_token = Accounts.generate_user_login_token(user)
    {:ok, {logged_in_user, persisted_login_token}} = Accounts.login_user(login_token)
    session_token = Accounts.generate_user_session_token(persisted_login_token, logged_in_user)

    conn =
      conn
      |> with_manage_host()
      |> init_test_session(user_token: session_token)

    {conn, logged_in_user.current_space_membership.space}
  end

  defp with_manage_host(conn) do
    case System.get_env("MAVE_MANAGE_HOST") do
      host when is_binary(host) and host != "" -> %{conn | host: host}
      _ -> conn
    end
  end
end
