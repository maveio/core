defmodule MaveCoreWeb.Live.Dashboard.Videos.IndexTest do
  use MaveCoreWeb.ConnCase, async: true

  import Phoenix.LiveViewTest

  alias MaveCore.Accounts
  alias MaveCore.Assets.{Asset, AudioTrack, Video}
  alias MaveCore.Collections.{Collection, CollectionEmbed}
  alias MaveCore.Embeds.{Embed, SettingsSerializer}
  alias MaveCore.Embeds.Events
  alias MaveCore.Flow
  alias MaveCore.Flow.{Run, StepRun, Version}
  alias MaveCore.Repo
  alias MaveCore.Spaces.Space
  alias MaveCoreWeb.DashboardRoutes

  test "/videos renders db-backed root data and not mock data", %{conn: conn} do
    {conn, space} = authenticated_conn(conn)
    root_video = video_embed_fixture(space, %{name: "DB Root Video"})
    root_folder = folder_embed_fixture(space, %{name: "DB Root Folder"})
    nested_video = video_embed_fixture(space, %{name: "Nested Child Video"})
    link_embed_to_folder(root_folder, nested_video)

    {:ok, _view, html} = live(conn, "/videos")

    assert html =~ "<title>mave - video components</title>"
    assert html =~ "DB Root Video"
    assert html =~ "DB Root Folder"
    refute html =~ "Nested Child Video"
    refute html =~ "Homepage Background Loop"
    assert html =~ "/videos/#{root_video.id}"
    assert html =~ "/videos/#{root_folder.id}"
    assert html =~ "#{root_video.hash}/thumbnail.jpg"
    refute html =~ "#{space.hash}#{root_video.hash}.webp"
    assert html =~ "all"
    assert html =~ "archive"
  end

  test "/videos centers the empty state in the available content area", %{conn: conn} do
    {conn, _space} = authenticated_conn(conn)

    {:ok, view, html} = live(conn, "/videos")

    assert html =~ "Create your first video"
    assert has_element?(view, "#videos-empty-state.min-h-full")
  end

  test "/videos signs private thumbnails for the matching video", %{conn: conn} do
    {conn, space} = authenticated_conn(conn)
    video = video_embed_fixture(space, %{name: "Private overview thumbnail"})

    video =
      video
      |> Ecto.Changeset.change(playback_visibility: :private, playback_status: :private)
      |> Repo.update!()

    %{videos: [row]} = MaveCore.Embeds.list_root_items(space)
    uri = URI.parse(row.thumb)
    assert uri.path == "/space-#{space.hash}/#{video.hash}/thumbnail.jpg"
    query = URI.decode_query(uri.query)
    assert query["X-Amz-Signature"]
    assert query["X-Amz-Expires"] == "86400"
    assert query["response-cache-control"] == "private, max-age=300"

    {:ok, view, _html} = live(conn, "/videos")
    assert has_element?(view, ~s([style*="#{uri.path}?"][style*="X-Amz-Signature="]))
    refute has_element?(view, ~s([style*="/api/v1/playback/media/"]))
  end

  test "/videos renders cache-busted custom thumbnails in overview rows", %{conn: conn} do
    {conn, space} = authenticated_conn(conn)
    video = video_embed_fixture(space, %{name: "Custom Overview Poster"})

    thumbnail_url =
      SettingsSerializer.storage_object_url("space-#{space.hash}", "#{video.hash}/thumbnail.jpg")

    {:ok, video} =
      MaveCore.Embeds.update_settings(video, %{
        poster: :upload,
        external_poster: thumbnail_url
      })

    inserted_at = ~U[2026-01-02 03:04:05Z]

    Repo.insert_all("renditions", [
      %{
        id: MaveCore.LegacyShortUUID.dump!(Ecto.UUID.generate()),
        video_id: MaveCore.LegacyShortUUID.dump!(video.asset.current_video_id),
        rendition_key: "#{video.hash}/thumbnail.jpg",
        type: "custom_thumbnail",
        codec: nil,
        container: "jpg",
        size: nil,
        progress: 100.0,
        file_size: 1_000,
        inserted_at: inserted_at,
        updated_at: inserted_at
      }
    ])

    {:ok, _view, html} = live(conn, "/videos")

    assert html =~ "Custom Overview Poster"
    assert html =~ "#{thumbnail_url}?e=#{DateTime.to_unix(inserted_at, :microsecond)}"
  end

  test "/videos labels audio uploads as Audio instead of Custom", %{conn: conn} do
    {conn, space} = authenticated_conn(conn)

    embed =
      video_embed_fixture(space, %{
        name: "Audio Recording",
        max_width: nil,
        max_height: nil,
        max_frame_rate: nil
      })

    embed = Repo.preload(embed, asset: :current_video)

    %AudioTrack{}
    |> AudioTrack.changeset(%{
      video_id: embed.asset.current_video.id,
      filename: "audio.mp3",
      codec: "mp3",
      language: "en",
      default: true
    })
    |> Repo.insert!()

    {:ok, view, html} = live(conn, "/videos")
    assert has_element?(view, ".font-condensed.text-xs", "Audio")
    refute html =~ "Custom"
  end

  test "/videos labels processing videos without showing custom resolution", %{conn: conn} do
    {conn, space} = authenticated_conn(conn)

    processing_video =
      video_embed_fixture(space, %{name: "Importing Video", status: "uploading"})

    {:ok, _view, html} = live(conn, "/videos")

    assert html =~ "Importing Video"
    assert html =~ "Processing"
    refute html =~ "Custom"
    refute html =~ "#{processing_video.hash}/thumbnail.jpg"
  end

  test "/videos labels queued input_url flow runs as queued", %{conn: conn} do
    {conn, space} = authenticated_conn(conn)
    video = video_embed_fixture(space, %{name: "Queued Import", status: "uploading"})
    create_processing_run(space, video, step_status: "queued")

    {:ok, _view, html} = live(conn, "/videos")

    assert html =~ "Queued Import"
    assert html =~ "Queued"
    refute html =~ "Processing"
    refute html =~ "Custom"
  end

  test "/videos replaces the upload icon as soon as a processing thumbnail is ready", %{
    conn: conn
  } do
    {conn, space} = authenticated_conn(conn)

    video =
      space
      |> video_embed_fixture(%{name: "Thumbnail Ready", status: "uploading"})
      |> Repo.preload(:asset)

    create_processing_run(space, video, step_status: "executing")
    inserted_at = ~U[2026-01-02 03:04:05Z]

    Repo.insert_all("renditions", [
      %{
        id: MaveCore.LegacyShortUUID.dump!(Ecto.UUID.generate()),
        video_id: MaveCore.LegacyShortUUID.dump!(video.asset.current_video_id),
        rendition_key: "#{video.hash}/thumbnail.jpg",
        type: "thumbnail",
        codec: "jpg",
        container: "jpg",
        size: nil,
        progress: 100.0,
        file_size: 1_000,
        inserted_at: inserted_at,
        updated_at: inserted_at
      }
    ])

    {:ok, view, html} = live(conn, "/videos")
    thumbnail_url = "#{video.hash}/thumbnail.jpg?e=#{DateTime.to_unix(inserted_at, :microsecond)}"

    assert html =~ "Thumbnail Ready"
    assert html =~ "Processing"
    assert html =~ thumbnail_url

    refute has_element?(
             view,
             "#video-row-#{video.id} svg path[d='M12 16V4M12 4L15.5 7.5M12 4L8.5 7.5']"
           )
  end

  test "/videos updates queued input_url flow rows to processing in realtime", %{conn: conn} do
    {conn, space} = authenticated_conn(conn)
    video = video_embed_fixture(space, %{name: "Realtime Import", status: "uploading"})
    {_run, step_run} = create_processing_run(space, video, step_status: "queued")

    {:ok, view, html} = live(conn, "/videos")

    assert html =~ "Realtime Import"
    assert html =~ "Queued"

    step_run
    |> StepRun.changeset(%{status: "executing"})
    |> Repo.update!()

    Events.broadcast_updated(space.id, video.id, %{"phase" => "processing"})

    assert_eventually(fn ->
      html = render(view)
      html =~ "Realtime Import" and html =~ "Processing" and not (html =~ "Queued")
    end)
  end

  test "/videos does not label playable videos as processing because background flow work remains",
       %{conn: conn} do
    {conn, space} = authenticated_conn(conn)
    video = video_embed_fixture(space, %{name: "Playable Import", status: "playable"})
    create_processing_run(space, video)

    {:ok, _view, html} = live(conn, "/videos")

    assert html =~ "Playable Import"
    refute html =~ "Processing"
  end

  test "/:space_id/videos opens the same root list for a shared space url", %{conn: conn} do
    {conn, space} = authenticated_conn(conn)
    root_video = video_embed_fixture(space, %{name: "Scoped Root Video"})

    {:ok, _view, html} = live(conn, DashboardRoutes.videos_path(space))

    assert html =~ "Scoped Root Video"
    assert html =~ DashboardRoutes.video_path(space, root_video.id)
  end

  test "/videos?tab=archive only renders archived root embeds", %{conn: conn} do
    {conn, space} = authenticated_conn(conn)
    _active = video_embed_fixture(space, %{name: "Active List Video", archived: false})
    _archived = video_embed_fixture(space, %{name: "Archived List Video", archived: true})

    {:ok, _view, html} = live(conn, "/videos?tab=archive")

    assert html =~ "Archived List Video"
    refute html =~ "Active List Video"
    assert html =~ "/videos?tab=archive"
    assert html =~ "?tab=archive"
  end

  test "/videos search shows suggestions by title and public embed id", %{conn: conn} do
    {conn, space} = authenticated_conn(conn)
    matching = video_embed_fixture(space, %{name: "Searchable Ocean Clip"})
    _other = video_embed_fixture(space, %{name: "Completely Different Title"})

    {:ok, view, _html} = live(conn, "/videos")

    html =
      view
      |> element("#search")
      |> render_keyup(%{"value" => "Ocean"})

    assert html =~ "Searchable Ocean Clip"
    assert html =~ "#{space.hash}#{matching.hash}"
    assert length(Regex.scan(~r/phx-click="search_embed"/, html)) == 1

    html =
      view
      |> element("#search")
      |> render_keyup(%{"value" => "#{space.hash}#{matching.hash}"})

    assert html =~ "Searchable Ocean Clip"
    assert html =~ "#{space.hash}#{matching.hash}"
  end

  test "/videos search suggestion click opens the selected video", %{conn: conn} do
    {conn, space} = authenticated_conn(conn)
    matching = video_embed_fixture(space, %{name: "Jump To Me"})

    {:ok, view, _html} = live(conn, "/videos")

    _html =
      view
      |> element("#search")
      |> render_keyup(%{"value" => "Jump"})

    {:error, {:live_redirect, %{to: to}}} =
      view
      |> element(~s(button[phx-click="search_embed"][phx-value-id="#{matching.id}"]))
      |> render_click()

    assert to == DashboardRoutes.video_path(space, matching.id)
  end

  test "/videos create menu creates a placeholder video and redirects to detail", %{conn: conn} do
    {conn, space} = authenticated_conn(conn)
    {:ok, view, _html} = live(conn, "/videos")

    {:error, {:live_redirect, %{to: to}}} =
      view
      |> element("#videos-create-button-video")
      |> render_click()

    assert String.starts_with?(to, "/videos/")

    created_id = dashboard_embed_id_from_path(to)

    assert {:ok, embed} = MaveCore.Embeds.resolve_dashboard_embed(space, created_id)
    assert embed.type == :video
    assert embed.space_id == space.id
    assert embed.archived == false
    assert embed.asset_id
  end

  test "/videos updates when another session creates a video in the space", %{conn: conn} do
    {conn, space} = authenticated_conn(conn)
    {:ok, view, html} = live(conn, "/videos")

    refute html =~ "Realtime Video"

    assert {:ok, _embed} =
             MaveCore.Embeds.create_video_embed(space, %{name: "Realtime Video"})

    assert_eventually(fn -> render(view) =~ "Realtime Video" end)
  end

  test "/videos?tab=archive create menu keeps archive context and creates archived placeholder",
       %{conn: conn} do
    {conn, space} = authenticated_conn(conn)
    {:ok, view, _html} = live(conn, "/videos?tab=archive")

    {:error, {:live_redirect, %{to: to}}} =
      view
      |> element("#videos-create-button-video")
      |> render_click()

    assert String.contains?(to, "?tab=archive")

    created_id = dashboard_embed_id_from_path(to)

    assert {:ok, embed} = MaveCore.Embeds.resolve_dashboard_embed(space, created_id)
    assert embed.archived == true
  end

  test "/videos create menu creates a folder and redirects to folder detail", %{conn: conn} do
    {conn, space} = authenticated_conn(conn)
    {:ok, view, _html} = live(conn, "/videos")

    {:error, {:live_redirect, %{to: to}}} =
      view
      |> element("#videos-create-button-folder")
      |> render_click()

    created_id = dashboard_embed_id_from_path(to)

    assert {:ok, embed} = MaveCore.Embeds.resolve_dashboard_embed(space, created_id)
    assert embed.type == :collection
    assert embed.space_id == space.id
    assert embed.archived == false
    assert embed.collection_id
  end

  test "/videos can drag a root video into a folder", %{conn: conn} do
    {conn, space} = authenticated_conn(conn)
    folder = folder_embed_fixture(space, %{name: "Move Target Folder"})
    video = video_embed_fixture(space, %{name: "Move Me"})

    {:ok, view, _html} = live(conn, "/videos")

    html = render_hook(view, "drop_embed", %{"id" => video.id, "to" => folder.id})

    assert html =~ "Item moved"

    root = MaveCore.Embeds.list_root_items(space, :all)
    refute Enum.any?(root.videos, &(&1.uuid == video.id))

    folder_items = MaveCore.Embeds.list_folder_items(space, folder)
    assert Enum.any?(folder_items.videos, &(&1.uuid == video.id))
  end

  test "/videos paginates like old mave and enables next after 15 items", %{conn: conn} do
    {conn, space} = authenticated_conn(conn)

    embeds =
      for index <- 1..16 do
        video_embed_fixture(space, %{name: "Paged Video #{index}"})
      end

    oldest = hd(embeds)
    newest = List.last(embeds)

    {:ok, view, html} = live(conn, "/videos")

    assert has_element?(view, "#video-row-#{newest.id}")
    refute has_element?(view, "#video-row-#{oldest.id}")
    assert length(Regex.scan(~r/id="video-row-/, html)) == 15
    refute html =~ ~s(phx-click="next_page" disabled)

    html =
      view
      |> render_click("next_page", %{})

    assert_patch(view, "/videos?page=2")
    assert has_element?(view, "#video-row-#{oldest.id}")
    refute has_element?(view, "#video-row-#{newest.id}")
    assert length(Regex.scan(~r/id="video-row-/, html)) == 1
    assert has_element?(view, ~s(button[phx-click="next_page"][disabled]))
  end

  test "/videos space picker can switch to another space", %{conn: conn} do
    email = "videos-space-create-#{System.unique_integer([:positive])}@example.com"
    {:ok, user} = Accounts.create_user(email)
    {:ok, updated_user} = Accounts.create_space_for_user(user)
    original_space_id = user.current_space_membership.space.id
    new_space_id = updated_user.current_space_membership.space.id

    original_space = user.current_space_membership.space
    new_space = updated_user.current_space_membership.space

    _original_video = video_embed_fixture(original_space, %{name: "Original Space Video"})
    _new_video = video_embed_fixture(new_space, %{name: "New Space Video"})

    login_token = Accounts.generate_user_login_token(updated_user)
    {:ok, {logged_in_user, persisted_login_token}} = Accounts.login_user(login_token)
    session_token = Accounts.generate_user_session_token(persisted_login_token, logged_in_user)

    conn =
      conn
      |> with_manage_host()
      |> init_test_session(user_token: session_token)

    {:ok, view, _html} = live(conn, "/videos")

    assert render(view) =~ "New Space Video"
    refute render(view) =~ "Original Space Video"

    {:error, {:redirect, %{to: to}}} =
      render_click(view, "switch_space", %{"id" => original_space_id})

    refreshed_user = Accounts.get_user_by_email(email)
    assert to == DashboardRoutes.videos_path(refreshed_user)

    {:ok, _redirected_view, redirected_html} = live(conn, "/videos")

    assert redirected_html =~ "Original Space Video"
    refute redirected_html =~ "New Space Video"

    assert refreshed_user.current_space_membership.space.id == original_space_id
    refute refreshed_user.current_space_membership.space.id == new_space_id
  end

  defp authenticated_conn(conn) do
    email = "videos-index-#{System.unique_integer([:positive])}@example.com"
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

  defp dashboard_embed_id_from_path(path) do
    path
    |> URI.parse()
    |> Map.fetch!(:path)
    |> String.split("/", trim: true)
    |> List.last()
  end

  defp video_embed_fixture(%Space{} = space, attrs) do
    asset =
      %Asset{}
      |> Asset.changeset(%{
        space_id: space.id,
        name: Map.get(attrs, :name, "Video Asset")
      })
      |> Repo.insert!()

    video =
      %Video{}
      |> Video.changeset(%{
        asset_id: asset.id,
        status: Map.get(attrs, :status, "ready"),
        file_name: "#{Map.get(attrs, :name, "video")}.mp4",
        max_width: Map.get(attrs, :max_width, 1920),
        max_height: Map.get(attrs, :max_height, 1080),
        max_frame_rate: Map.get(attrs, :max_frame_rate, 30.0),
        max_bitrate: Map.get(attrs, :max_bitrate, 10_000_000),
        duration: 40.0,
        aspect_ratio: "16/9",
        original_file_size: 100_000_000
      })
      |> Repo.insert!()

    asset
    |> Ecto.Changeset.change(current_video_id: video.id)
    |> Repo.update!()

    %Embed{}
    |> Embed.changeset(%{
      space_id: space.id,
      asset_id: asset.id,
      hash: unique_embed_hash(),
      type: :video,
      version: 2,
      archived: Map.get(attrs, :archived, false)
    })
    |> Repo.insert!()
  end

  defp folder_embed_fixture(%Space{} = space, attrs) do
    collection =
      %Collection{}
      |> Collection.changeset(%{
        space_id: space.id,
        name: Map.get(attrs, :name, "Folder"),
        type: :folder
      })
      |> Repo.insert!()

    %Embed{}
    |> Embed.changeset(%{
      space_id: space.id,
      collection_id: collection.id,
      hash: unique_embed_hash(),
      type: :collection,
      version: 2,
      archived: Map.get(attrs, :archived, false)
    })
    |> Repo.insert!()
  end

  defp link_embed_to_folder(folder_embed, child_embed) do
    %CollectionEmbed{}
    |> CollectionEmbed.changeset(%{
      collection_id: folder_embed.collection_id,
      embed_id: child_embed.id
    })
    |> Repo.insert!()
  end

  defp create_processing_run(%Space{} = space, %Embed{} = embed, opts \\ []) do
    step_status = Keyword.get(opts, :step_status, "queued")

    {:ok, template} =
      Flow.create_template(%{
        "slug" => "processing-list-#{System.unique_integer([:positive])}",
        "name" => "Processing List"
      })

    {:ok, %Version{} = version} =
      Flow.create_version(template.id, %{
        "definition" => %{
          "steps" => [
            %{"id" => "source", "type" => "source.resolve", "name" => "Resolve Source"}
          ]
        }
      })

    %Run{}
    |> Run.changeset(%{
      flow_template_id: template.id,
      flow_version_id: version.id,
      status: "running",
      input: %{
        "space_hash" => space.hash,
        "embed_hash" => embed.hash,
        "input_url" => "https://example.com/video.mp4"
      },
      context: %{}
    })
    |> Repo.insert!()
    |> then(fn run ->
      step_run =
        %StepRun{}
        |> StepRun.changeset(%{
          flow_run_id: run.id,
          step_id: "source",
          step_type: "source.resolve",
          status: step_status,
          attempt: 0,
          input: %{},
          execution_metadata: %{}
        })
        |> Repo.insert!()

      {run, step_run}
    end)
  end

  defp unique_embed_hash do
    System.unique_integer([:positive])
    |> Integer.to_string(36)
    |> String.pad_leading(10, "0")
    |> String.slice(-10, 10)
  end
end
