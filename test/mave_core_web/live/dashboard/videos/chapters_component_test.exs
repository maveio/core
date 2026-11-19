defmodule MaveCoreWeb.Live.Dashboard.Videos.ChaptersComponentTest do
  use MaveCoreWeb.ConnCase, async: false

  import Phoenix.LiveViewTest

  alias MaveCore.Accounts
  alias MaveCore.Assets.{Asset, ChapterSet, Subtitle, Video}
  alias MaveCore.Chapters
  alias MaveCore.Embeds.Embed
  alias MaveCore.Media.Storage
  alias MaveCore.Repo
  alias MaveCore.TestSupport.ChapterTranscriptFixture, as: Fixture
  alias MaveCore.TestSupport.FlowStorageAdapterStub
  alias MaveCoreWeb.Dashboard.Videos.ChaptersComponent

  defmodule NoChapters do
    @behaviour MaveCore.UsageLimits
    def can_create_video_embed?(_space), do: :ok
    def can_add_space_member?(_space, _role), do: :ok
    def can_use_automatic_chapters?(_space), do: {:error, :paid_plan_required}
  end

  setup do
    previous = %{
      flow_storage_adapter: Application.get_env(:mave_core, :flow_storage_adapter),
      cdn_cache_purger: Application.get_env(:mave_core, :cdn_cache_purger),
      chapters: Application.get_env(:mave_core, :chapters),
      usage_limits_backend: Application.get_env(:mave_core, :usage_limits_backend)
    }

    Application.put_env(:mave_core, :flow_storage_adapter, FlowStorageAdapterStub)
    Application.put_env(:mave_core, :cdn_cache_purger, fn _, _, _ -> :ok end)
    Application.put_env(:mave_core, :chapters, writer: MaveCore.Chapters.LocalWriter)
    FlowStorageAdapterStub.reset!()

    on_exit(fn ->
      for {key, value} <- previous do
        if is_nil(value),
          do: Application.delete_env(:mave_core, key),
          else: Application.put_env(:mave_core, key, value)
      end

      FlowStorageAdapterStub.reset!()
    end)

    :ok
  end

  test "suggests chapters from the subtitles as a draft", %{conn: conn} do
    {conn, space} = authenticated_conn(conn)
    embed = video_embed_fixture(space)
    {:ok, view, _html} = live(conn, "/videos/#{embed.id}")

    assert has_element?(view, "#chapters-status", "No chapters yet")
    assert has_element?(view, "#chapters-publish[disabled]")

    # Without subtitles there is nothing to suggest from.
    view |> element("#chapters-suggest") |> render_click()
    assert render(view) =~ "This video has no subtitles yet"
    refute has_element?(view, "[data-chapter-row]")

    subtitle_fixture(space, embed)
    view |> element("#chapters-suggest") |> render_click()
    html = render(view)

    assert has_element?(view, "#chapters-status", "Draft · not visible to viewers")
    assert has_element?(view, "#chapters-provenance", "a suggestion based on the transcript")

    assert titles(html) ==
             ["Garden, soil, seeds", "Bicycle, chain, brakes", "Flour, dough, oven"] ++
               ["Camera, lens, photos"]

    assert times(html) == ["0:00", "0:35", "1:11", "1:47"]
    assert Chapters.published_cues(current_video(embed)) == []
  end

  test "edits are saved to the draft and shown to viewers after publishing", %{conn: conn} do
    {conn, space} = authenticated_conn(conn)
    embed = video_embed_fixture(space)
    video = current_video(embed)

    {:ok, _set} =
      Chapters.save_draft(video, [
        %{"start" => 0, "title" => "Intro"},
        %{"start" => 35.7, "title" => "Bicycle"}
      ])

    {:ok, view, html} = live(conn, "/videos/#{embed.id}")
    [first, second] = row_ids(html)

    # The draft is what the preview player shows on its timeline.
    assert preview(html) == [
             %{"start" => 0.0, "title" => "Intro"},
             %{"start" => 35.7, "title" => "Bicycle"}
           ]

    html = change(view, %{second => %{"time" => "1:10.5", "title" => "Bread"}})
    assert times(html) == ["0:00", "1:10"]

    assert %ChapterSet{draft: [_, %{"start" => 70.5, "title" => "Bread"}], published: []} =
             Chapters.get_set(video.id)

    # A title change keeps the precise start time.
    change(view, %{second => %{"time" => "1:10", "title" => "Baking bread"}})
    assert %ChapterSet{draft: [_, %{"start" => 70.5}]} = Chapters.get_set(video.id)

    view |> element("#chapters-publish") |> render_click()
    assert has_element?(view, "#chapters-status", "Published · 2 chapters")
    assert has_element?(view, "#chapters-publish[disabled]")

    assert [%{"title" => "Intro"}, %{"start" => 70.5, "title" => "Baking bread"}] =
             Chapters.published_cues(video)

    change(view, %{first => %{"time" => "0:00", "title" => "Welcome"}})
    assert has_element?(view, "#chapters-status", "changes that viewers don't see yet")
    assert [%{"title" => "Intro"}, _] = Chapters.published_cues(video)

    view |> element("#chapters-unpublish") |> render_click()
    assert has_element?(view, "#chapters-status", "Draft · not visible to viewers")
    assert Chapters.published_cues(video) == []
  end

  test "adds a chapter at the playback position and removes chapters", %{conn: conn} do
    {conn, space} = authenticated_conn(conn)
    embed = video_embed_fixture(space)
    video = current_video(embed)
    {:ok, _set} = Chapters.save_draft(video, [%{"start" => 0, "title" => "Intro"}])
    {:ok, view, _html} = live(conn, "/videos/#{embed.id}")

    # The hook sends the player's current time.
    html = view |> with_target("#video-chapters") |> render_hook("add_chapter", %{"time" => 61.8})
    assert times(html) == ["0:00", "1:01"]
    assert titles(html) == ["Intro", "New chapter"]

    # The same position again takes the next free second.
    html = view |> with_target("#video-chapters") |> render_hook("add_chapter", %{"time" => 61.2})
    assert times(html) == ["0:00", "1:01", "1:02"]

    [_, _, last] = row_ids(html)
    html = view |> element("#chapter-remove-#{last}") |> render_click()
    assert times(html) == ["0:00", "1:01"]

    assert %ChapterSet{draft: [%{"start" => +0.0}, %{"start" => 61.0, "title" => "New chapter"}]} =
             Chapters.get_set(video.id)
  end

  test "marks a chapter that cannot be saved and keeps the stored draft", %{conn: conn} do
    {conn, space} = authenticated_conn(conn)
    embed = video_embed_fixture(space)
    video = current_video(embed)

    {:ok, _set} =
      Chapters.save_draft(video, [
        %{"start" => 0, "title" => "Intro"},
        %{"start" => 35.7, "title" => "Bicycle"}
      ])

    {:ok, view, html} = live(conn, "/videos/#{embed.id}")
    [_first, second] = row_ids(html)

    for {input, message} <- [
          {%{"time" => "soon", "title" => "Bicycle"}, "Use a time like 1:30"},
          {%{"time" => "0:00", "title" => "Bicycle"}, "Another chapter starts here"},
          {%{"time" => "9:59", "title" => "Bicycle"}, "After the end of the video"},
          {%{"time" => "0:35", "title" => " "}, "Add a title"}
        ] do
      html = change(view, %{second => input})
      assert html =~ message
      assert has_element?(view, "#chapters-error", "Not saved yet")
      assert has_element?(view, "#chapters-publish[disabled]")
    end

    assert %ChapterSet{draft: [_, %{"start" => 35.7, "title" => "Bicycle"}]} =
             Chapters.get_set(video.id)

    change(view, %{second => %{"time" => "0:40", "title" => "Bicycle"}})
    refute has_element?(view, "#chapters-error")
    assert %ChapterSet{draft: [_, %{"start" => 40.0}]} = Chapters.get_set(video.id)
  end

  test "asks before a new suggestion replaces the draft", %{conn: conn} do
    {conn, space} = authenticated_conn(conn)
    embed = video_embed_fixture(space)
    video = current_video(embed)
    subtitle_fixture(space, embed)
    {:ok, _set} = Chapters.save_draft(video, [%{"start" => 0, "title" => "Mine"}])
    {:ok, view, _html} = live(conn, "/videos/#{embed.id}")

    view |> element("#chapters-suggest") |> render_click()
    assert has_element?(view, "#chapters-confirm-replace")
    view |> element("#chapters-cancel-suggest") |> render_click()
    assert titles(render(view)) == ["Mine"]

    view |> element("#chapters-suggest") |> render_click()
    view |> element("#chapters-confirm-suggest") |> render_click()
    assert length(titles(render(view))) == 4
  end

  test "shows a suggestion that arrives while the page is open", %{conn: conn} do
    {conn, space} = authenticated_conn(conn)
    embed = video_embed_fixture(space)
    subtitle_fixture(space, embed)
    {:ok, view, _html} = live(conn, "/videos/#{embed.id}")
    refute has_element?(view, "[data-chapter-row]")

    assert {:ok, _set} = Chapters.generate(embed, current_video(embed).id)
    # The page handles the update first and then refreshes the editor.
    _ = render(view)
    assert length(titles(render(view))) == 4
  end

  test "hides suggestions when the host does not allow them", %{conn: conn} do
    {conn, space} = authenticated_conn(conn)
    embed = video_embed_fixture(space)
    Application.put_env(:mave_core, :usage_limits_backend, NoChapters)
    {:ok, view, _html} = live(conn, "/videos/#{embed.id}")

    refute has_element?(view, "#chapters-suggest")
    assert has_element?(view, "#chapters-add")
  end

  test "reads times as people write them" do
    assert ChaptersComponent.parse_time("90") == 90.0
    assert ChaptersComponent.parse_time("1:30") == 90.0
    assert ChaptersComponent.parse_time(" 1:30,5 ") == 90.5
    assert ChaptersComponent.parse_time("1:02:03") == 3723.0
    assert ChaptersComponent.parse_time("1:75") == nil
    assert ChaptersComponent.parse_time("1.5:10") == nil
    assert ChaptersComponent.parse_time("soon") == nil

    assert ChaptersComponent.format_time(0) == "0:00"
    assert ChaptersComponent.format_time(90.9) == "1:30"
    assert ChaptersComponent.format_time(3723) == "1:02:03"
  end

  defp change(view, chapters) do
    view |> form("#chapters-form") |> render_change(%{"chapters" => chapters})
  end

  defp row_ids(html) do
    ~r/id="chapter-title-(c\d+)"/ |> Regex.scan(html) |> Enum.map(&List.last/1)
  end

  defp titles(html), do: input_values(html, "chapter-title")
  defp times(html), do: input_values(html, "chapter-time")

  defp input_values(html, prefix) do
    html
    |> LazyHTML.from_fragment()
    |> LazyHTML.query(~s(input[id^="#{prefix}-"]))
    |> LazyHTML.attribute("value")
  end

  defp preview(html) do
    html
    |> LazyHTML.from_fragment()
    |> LazyHTML.query("#video-chapters")
    |> LazyHTML.attribute("data-chapters")
    |> hd()
    |> Jason.decode!()
  end

  defp current_video(%Embed{} = embed) do
    Repo.preload(embed, asset: [:current_video]).asset.current_video
  end

  defp subtitle_fixture(space, embed) do
    bucket = Storage.bucket_for_space(space.hash, space.region)
    path = "#{embed.hash}/subtitle_en.vtt"
    FlowStorageAdapterStub.put(bucket, path, Fixture.vtt(), "text/vtt", space.region)

    Repo.insert!(%Subtitle{video_id: current_video(embed).id, language: "en", path: path})
  end

  defp video_embed_fixture(space) do
    asset = %Asset{} |> Asset.changeset(%{space_id: space.id, name: "Chapters"}) |> Repo.insert!()

    video =
      %Video{}
      |> Video.changeset(%{
        asset_id: asset.id,
        status: "ready",
        file_name: "chapters.mp4",
        max_width: 1920,
        max_height: 1080,
        max_frame_rate: 30.0,
        max_bitrate: 10_000_000,
        duration: Fixture.duration(),
        aspect_ratio: "16/9",
        original_file_size: 100_000_000
      })
      |> Repo.insert!()

    asset |> Ecto.Changeset.change(current_video_id: video.id) |> Repo.update!()

    hash =
      System.unique_integer([:positive])
      |> Integer.to_string(36)
      |> String.pad_leading(10, "0")
      |> String.slice(-10, 10)

    %Embed{}
    |> Embed.changeset(%{space_id: space.id, asset_id: asset.id, hash: hash, type: :video})
    |> Repo.insert!()
  end

  defp authenticated_conn(conn) do
    email = "chapters-#{System.unique_integer([:positive])}@example.com"
    {:ok, user} = Accounts.create_user(email)
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
