defmodule MaveCoreWeb.Live.Dashboard.Videos.ContentSearchTest do
  use MaveCoreWeb.ConnCase, async: false

  import Phoenix.LiveViewTest

  alias MaveCore.Accounts
  alias MaveCore.Assets.{Asset, Video}
  alias MaveCore.Embeds
  alias MaveCore.Repo
  alias MaveCore.Search
  alias MaveCore.Spaces.Space
  alias MaveCoreWeb.DashboardRoutes

  test "the search box finds videos by what is on screen and opens the moment", %{conn: conn} do
    {conn, space} = authenticated_conn(conn)

    tour =
      video(space, "Harbour tour", nil, [
        %{source: "visual", start: 72.0, end: 75.0, text: "A woman rides a red bicycle."},
        %{source: "transcript", start: 80.0, end: 84.0, text: "That bicycle is older than me."}
      ])

    other = video(space, "Budget review", nil, [])

    {:ok, view, _html} = live(conn, "/videos")

    # A click binding on the debounced input is dropped once typing starts.
    assert has_element?(view, "#search-box[phx-click]")
    refute has_element?(view, "#search[phx-click]")

    view |> element("#search") |> render_keyup(%{"value" => "bicy"})

    assert has_element?(view, "#suggest-#{tour.id}", "Harbour tour")
    refute has_element?(view, "#suggest-#{other.id}")
    refute has_element?(view, "#search-scope")
    assert has_element?(view, "#suggest-#{tour.id}-moment-0 mark", "bicycle")
    assert has_element?(view, "#suggest-#{tour.id}-moment-0", "1:12")
    assert has_element?(view, "#suggest-#{tour.id}-moment-1", "1:20")

    {:error, {:live_redirect, %{to: to}}} =
      view |> element("#suggest-#{tour.id}-moment-0") |> render_click()

    assert to == DashboardRoutes.video_path(space, tour.id, :all, time: 72.0)
    assert to =~ "t=72.0"
  end

  test "inside a folder the search is limited to it until the library is chosen", %{conn: conn} do
    {conn, space} = authenticated_conn(conn)
    {:ok, folder} = Embeds.create_folder_embed(space, %{name: "Courses"})
    moments = [%{source: "visual", start: 5.0, end: 8.0, text: "Hands knead dough."}]

    inside = video(space, "Sourdough", folder.id, moments)
    outside = video(space, "Pizza night", nil, moments)

    {:ok, view, _html} = live(conn, DashboardRoutes.video_path(space, folder.id))
    view |> element("#search") |> render_keyup(%{"value" => "dough"})

    assert has_element?(view, ~s(#search-scope-collection[aria-pressed="true"]), "Courses")
    assert has_element?(view, "#suggest-#{inside.id}")
    refute has_element?(view, "#suggest-#{outside.id}")

    view |> element("#search-scope-library") |> render_click()

    assert has_element?(view, ~s(#search-scope-library[aria-pressed="true"]))
    assert has_element?(view, ~s(#search[value="dough"]))
    assert has_element?(view, "#suggest-#{inside.id}")
    assert has_element?(view, "#suggest-#{outside.id}")
  end

  test "a video opened from a moment starts there", %{conn: conn} do
    {conn, space} = authenticated_conn(conn)
    embed = video(space, "Harbour tour", nil, [])

    {:ok, view, _html} = live(conn, DashboardRoutes.video_path(space, embed.id, :all, time: 72.0))
    assert has_element?(view, ~s(#video-components-loader[data-start-time="72.0"]))

    {:ok, view, _html} = live(conn, DashboardRoutes.video_path(space, embed.id) <> "?t=soon")
    refute has_element?(view, "#video-components-loader[data-start-time]")
  end

  test "a space turns searchable video on in its settings", %{conn: conn} do
    {conn, space} = authenticated_conn(conn)
    {:ok, view, _html} = live(conn, "/settings")

    refute has_element?(view, "#video-search-notice")

    view |> element("#video-search-toggle") |> render_click()
    assert Repo.get!(Space, space.id).video_search_enabled

    view |> element("#video-search-toggle") |> render_click()
    refute Repo.get!(Space, space.id).video_search_enabled
  end

  defp video(space, name, parent_folder_id, moments) do
    {:ok, embed} =
      Embeds.create_video_embed(space, %{name: name, parent_folder_id: parent_folder_id})

    video =
      Repo.insert!(%Video{
        asset_id: embed.asset_id,
        status: "ready",
        file_name: "#{name}.mp4",
        duration: 120.0
      })

    Asset
    |> Repo.get!(embed.asset_id)
    |> Ecto.Changeset.change(current_video_id: video.id)
    |> Repo.update!()

    {:ok, _count} = Search.index_video(video, space.id, moments)
    embed
  end

  defp authenticated_conn(conn) do
    email = "content-search-#{System.unique_integer([:positive])}@example.com"
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
