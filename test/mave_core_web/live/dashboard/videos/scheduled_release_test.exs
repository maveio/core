defmodule MaveCoreWeb.Live.Dashboard.Videos.ScheduledReleaseTest do
  use MaveCoreWeb.ConnCase, async: false

  import Phoenix.LiveViewTest

  alias MaveCore.{Accounts, Embeds, Repo}
  alias MaveCore.Embeds.{Embed, Release}
  alias MaveCore.TestSupport.FlowStorageAdapterStub

  def available?(_space), do: true

  # Storage synchronization runs inline inside the LiveView process.
  def apply_visibility(embed, visibility) do
    send(__MODULE__, {:storage_visibility, embed.id, visibility})
    :ok
  end

  setup do
    Process.register(self(), __MODULE__)

    previous =
      for key <- [:playback_adapter, :flow_storage_adapter],
          into: %{},
          do: {key, Application.get_env(:mave_core, key)}

    Application.put_env(:mave_core, :playback_adapter, __MODULE__)
    Application.put_env(:mave_core, :flow_storage_adapter, FlowStorageAdapterStub)
    FlowStorageAdapterStub.reset!()

    on_exit(fn ->
      FlowStorageAdapterStub.reset!()

      Enum.each(previous, fn {key, value} ->
        if value,
          do: Application.put_env(:mave_core, key, value),
          else: Application.delete_env(:mave_core, key)
      end)
    end)

    :ok
  end

  test "owners schedule, see and publish a release from the video page", %{conn: conn} do
    {conn, space} = authenticated_conn(conn)
    {:ok, embed} = Embeds.create_video_embed(space)
    {:ok, embed} = Embeds.begin_video_upload(space.hash, embed.hash, %{"title" => "launch.mp4"})

    {:ok, view, _html} = live(conn, "/videos/#{embed.id}")
    refute has_element?(view, "#scheduled-release-notice")
    assert has_element?(view, "#video-schedule-release", "schedule release")

    view |> element("#video-schedule-release") |> render_click()
    assert has_element?(view, "#release-form")

    # The release_time_input hook fills this hidden UTC field in the browser.
    view
    |> form("#release-form")
    |> render_submit(%{release: %{at: "2020-01-01T10:00:00Z"}})

    refute Release.pending?(Repo.get!(Embed, embed.id))

    # The release_time_input hook fills this hidden UTC field in the browser.
    view
    |> form("#release-form")
    |> render_submit(%{release: %{at: "2099-06-01T16:00:00.000Z"}})

    assert_receive {:storage_visibility, _id, :private}
    assert %Embed{release_at: ~U[2099-06-01 16:00:00.000000Z]} = Repo.get!(Embed, embed.id)

    assert has_element?(view, "#scheduled-release-notice time[datetime^='2099-06-01T16:00:00']")
    assert has_element?(view, "#video-schedule-release", "change release")
    assert has_element?(view, "#video-playback-visibility[aria-disabled]")
    refute has_element?(view, "#private-playback-guide")
    refute has_element?(view, "#snippet-code", "YOUR_PLAYBACK_TOKEN")

    view |> element("#scheduled-release-notice-publish") |> render_click()

    assert_receive {:storage_visibility, _id, :public}
    assert %Embed{release_at: nil, playback_visibility: :public} = Repo.get!(Embed, embed.id)
    refute has_element?(view, "#scheduled-release-notice")
  end

  defp authenticated_conn(conn) do
    {:ok, user} =
      Accounts.create_user("release-show-#{System.unique_integer([:positive])}@example.com")

    login_token = Accounts.generate_user_login_token(user)
    {:ok, {logged_in_user, persisted_login_token}} = Accounts.login_user(login_token)
    session_token = Accounts.generate_user_session_token(persisted_login_token, logged_in_user)

    conn =
      case System.get_env("MAVE_MANAGE_HOST") do
        host when is_binary(host) and host != "" -> %{conn | host: host}
        _ -> conn
      end

    {init_test_session(conn, user_token: session_token),
     logged_in_user.current_space_membership.space}
  end
end
