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

  defmodule HostManaged do
    @behaviour MaveCore.UsageLimits
    def can_create_video_embed?(_space), do: :ok
    def can_add_space_member?(_space, _role), do: :ok
    def can_manage_audio_description?(_space), do: {:error, :managed_feature}
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

    assert space.automatic_subtitles_enabled
    refute space.audio_description_enabled
    view |> element("#automatic-subtitles-toggle") |> render_click()
    refute Repo.get!(Space, space.id).automatic_subtitles_enabled

    view |> element("#audio-description-toggle") |> render_click()
    assert Repo.get!(Space, space.id).audio_description_enabled
    refute Repo.get!(Space, space.id).automatic_subtitles_enabled

    view |> element("#audio-description-toggle") |> render_click()
    refute Repo.get!(Space, space.id).audio_description_enabled
  end

  test "edits custom vocabulary for this space while AI subtitles are enabled", %{conn: conn} do
    {conn, space} = authenticated_conn(conn)
    {:ok, view, _} = live(conn, "/settings")
    view |> element("#edit-subtitle-vocabulary") |> render_click()

    form = fn text ->
      view |> form("#subtitle-vocabulary-form", vocabulary: %{terms: text}) |> render_submit()
    end

    form.("Open Science\nKB\n kb ")
    assert Repo.get!(Space, space.id).subtitle_vocabulary == ["Open Science", "KB"]
    view |> element("#edit-subtitle-vocabulary") |> render_click()
    assert has_element?(view, "#subtitle-vocabulary-form textarea", "Open Science")
    form.(String.duplicate("x", 81))
    assert has_element?(view, "#subtitle-vocabulary-form", "up to 25")
    assert Repo.get!(Space, space.id).subtitle_vocabulary == ["Open Science", "KB"]
    form.("")
    assert Repo.get!(Space, space.id).subtitle_vocabulary == []
    view |> element("#automatic-subtitles-toggle") |> render_click()
    refute has_element?(view, "#edit-subtitle-vocabulary")
    assert {:error, :disabled} = MaveCore.Spaces.update_subtitle_vocabulary(space, "Example")
  end

  test "shows the host's notice and keeps the toggle off when not allowed", %{conn: conn} do
    {conn, space} = authenticated_conn(conn)
    Application.put_env(:mave_core, :usage_limits_backend, PaidOnly)
    {:ok, view, html} = live(conn, "/settings")

    assert html =~ "Available on paid plans"
    assert has_element?(view, "#audio-description-toggle.pointer-events-none")
    refute Repo.get!(Space, space.id).audio_description_enabled
  end

  test "hides settings when the host manages audio description", %{conn: conn} do
    {conn, _space} = authenticated_conn(conn)
    Application.put_env(:mave_core, :usage_limits_backend, HostManaged)
    {:ok, view, _html} = live(conn, "/settings")

    refute has_element?(view, "#audio-description-feature")
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
