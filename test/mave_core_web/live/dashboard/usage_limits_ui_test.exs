defmodule MaveCoreWeb.Live.Dashboard.UsageLimitsUITest do
  use MaveCoreWeb.ConnCase, async: false

  import Phoenix.LiveViewTest

  alias MaveCore.Accounts
  alias MaveCore.Embeds
  alias MaveCore.PublicApi

  defmodule VideoBlockedUsageLimits do
    @behaviour MaveCore.UsageLimits

    def can_create_video_embed?(_space), do: {:error, :embed_limit_reached}
    def can_add_space_member?(_space, _role), do: :ok
    def can_view_space_data?(_space), do: :ok
  end

  defmodule TeamBlockedUsageLimits do
    @behaviour MaveCore.UsageLimits

    def can_create_video_embed?(_space), do: :ok
    def can_add_space_member?(_space, _role), do: {:error, :team_member_limit_reached}
    def can_view_space_data?(_space), do: :ok
  end

  defmodule DataBlockedUsageLimits do
    @behaviour MaveCore.UsageLimits

    def can_create_video_embed?(_space), do: :ok
    def can_add_space_member?(_space, _role), do: :ok
    def can_view_space_data?(_space), do: {:error, :data_unavailable}
  end

  setup do
    old_backend = Application.get_env(:mave_core, :usage_limits_backend)

    on_exit(fn ->
      restore_usage_limits_backend(old_backend)
    end)

    :ok
  end

  test "/videos uses neutral copy when a host blocks video creation", %{conn: conn} do
    {conn, _space} = authenticated_conn(conn)
    Application.put_env(:mave_core, :usage_limits_backend, VideoBlockedUsageLimits)

    {:ok, view, html} = live(conn, "/videos")

    assert html =~ ~s(id="videos-create-video-limit-notice")
    assert html =~ "Video creation is unavailable"
    assert html =~ "This space cannot create more videos right now."
    refute html =~ "plan"
    refute html =~ "upgrade"
    assert ordered?(html, ~s(id="videos-create-video-limit-notice"), ~s(id="videos-tab-all"))
    assert ordered?(html, ~s(id="videos-tab-archive"), ~s(id="videos-create-button"))
    assert has_element?(view, "#videos-create-button-video[aria-disabled]")
    assert has_element?(view, "#videos-empty-create-button-video[aria-disabled]")
  end

  test "/videos rejects replayed create video events with neutral copy", %{
    conn: conn
  } do
    {conn, space} = authenticated_conn(conn)
    Application.put_env(:mave_core, :usage_limits_backend, VideoBlockedUsageLimits)

    {:ok, view, _html} = live(conn, "/videos")

    assert PublicApi.count_videos(space, show_collections: true) == 0

    html = render_click(view, "create_video", %{})

    assert html =~ "Could not create video"
    assert PublicApi.count_videos(space, show_collections: true) == 0
  end

  test "/videos/:id folder mode disables only video creation with neutral copy", %{
    conn: conn
  } do
    {conn, space} = authenticated_conn(conn)
    {:ok, folder} = Embeds.create_folder_embed(space, %{name: "Plan Locked Folder"})
    Application.put_env(:mave_core, :usage_limits_backend, VideoBlockedUsageLimits)

    {:ok, view, html} = live(conn, "/videos/#{Embeds.dashboard_embed_id(folder)}")

    assert html =~ ~s(id="folder-create-video-limit-notice")
    assert html =~ "Video creation is unavailable"
    assert html =~ "This space cannot create more videos right now."
    assert has_element?(view, "#folder-create-video[aria-disabled]")
    assert has_element?(view, "#folder-create-folder")
  end

  test "/videos/:id folder mode rejects replayed create video events when the plan limit is reached",
       %{
         conn: conn
       } do
    {conn, space} = authenticated_conn(conn)
    {:ok, folder} = Embeds.create_folder_embed(space, %{name: "Replay Locked Folder"})
    Application.put_env(:mave_core, :usage_limits_backend, VideoBlockedUsageLimits)

    {:ok, view, _html} = live(conn, "/videos/#{Embeds.dashboard_embed_id(folder)}")

    html = render_click(view, "create_video", %{})

    assert html =~ "Could not create video"
    assert %{videos: []} = Embeds.list_folder_items(space, folder)
  end

  test "/settings/team uses neutral copy when a host blocks member creation", %{conn: conn} do
    {conn, _space} = authenticated_conn(conn)
    Application.put_env(:mave_core, :usage_limits_backend, TeamBlockedUsageLimits)

    {:ok, view, html} = live(conn, "/settings/team")

    assert html =~ ~s(id="settings-add-member-limit-notice")
    assert html =~ "Team member invites are unavailable"
    assert html =~ "This space cannot add more team members right now."
    refute html =~ "plan"
    refute html =~ "upgrade"
    assert has_element?(view, "#settings-add-member-button[disabled]")
  end

  test "/data uses neutral copy when a host blocks analytics", %{conn: conn} do
    {conn, _space} = authenticated_conn(conn)
    Application.put_env(:mave_core, :usage_limits_backend, DataBlockedUsageLimits)

    {:ok, _view, html} = live(conn, "/data")

    assert html =~ ~s(id="data-access-limit-notice")
    assert html =~ "Data is unavailable"
    assert html =~ "This space cannot view statistics right now."
    refute html =~ "plan"
    refute html =~ "upgrade"
  end

  defp authenticated_conn(conn) do
    email = "usage-limits-ui-#{System.unique_integer([:positive])}@example.com"
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

  defp restore_usage_limits_backend(nil),
    do: Application.delete_env(:mave_core, :usage_limits_backend)

  defp restore_usage_limits_backend(backend),
    do: Application.put_env(:mave_core, :usage_limits_backend, backend)

  defp ordered?(html, first, second) do
    first_at = :binary.match(html, first)
    second_at = :binary.match(html, second)

    match?({first_index, _} when is_integer(first_index), first_at) and
      match?({second_index, _} when is_integer(second_index), second_at) and
      elem(first_at, 0) < elem(second_at, 0)
  end
end
