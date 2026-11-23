defmodule MaveCoreWeb.Live.Dashboard.Videos.SubtitlesTest do
  use MaveCoreWeb.ConnCase, async: false

  import Phoenix.LiveViewTest

  alias MaveCore.Accounts
  alias MaveCore.Assets.{Asset, Subtitle, Video}
  alias MaveCore.Embeds.Embed
  alias MaveCore.Media.Storage
  alias MaveCore.Repo
  alias MaveCore.Spaces.Space
  alias MaveCore.TestSupport.FlowStorageAdapterStub

  @english """
  WEBVTT

  00:00:01.000 --> 00:00:04.000
  Every morning, before the city wakes,

  00:00:04.500 --> 00:00:09.000
  What isn't sold at the quay goes to the smokehouse two streets away,

  00:00:10.000 --> 00:00:12.000
  Nothing here goes to waste.
  """

  @dutch """
  WEBVTT

  00:00:01.000 --> 00:00:04.000
  Elke ochtend, voordat de stad wakker wordt,

  00:00:04.500 --> 00:00:09.000
  Wat niet op de kade wordt verkocht, gaat naar de rokerij.
  """

  setup do
    old_storage_adapter = Application.get_env(:mave_core, :flow_storage_adapter)
    Application.put_env(:mave_core, :flow_storage_adapter, FlowStorageAdapterStub)
    FlowStorageAdapterStub.reset!()

    on_exit(fn ->
      if old_storage_adapter,
        do: Application.put_env(:mave_core, :flow_storage_adapter, old_storage_adapter),
        else: Application.delete_env(:mave_core, :flow_storage_adapter)

      FlowStorageAdapterStub.reset!()
    end)

    :ok
  end

  test "the video page links each subtitle to the editor", %{conn: conn} do
    {conn, space} = authenticated_conn(conn)
    video = video_embed_fixture(space)
    subtitle = subtitle_fixture(space, video, "en", @english)

    {:ok, view, _html} = live(conn, "/videos/#{video.id}")

    assert has_element?(
             view,
             ~s(a#subtitle-edit-text-#{subtitle.id}[href="/videos/#{video.id}/subtitles/#{subtitle.id}"]),
             "Edit text"
           )
  end

  test "shows the cues, their checks and the other languages", %{conn: conn} do
    {conn, space} = authenticated_conn(conn)
    video = video_embed_fixture(space)
    english = subtitle_fixture(space, video, "en", @english)
    dutch = subtitle_fixture(space, video, "nl", @dutch)

    {:ok, view, _html} = live(conn, editor_path(video, english))

    assert view |> element("#subtitle-cue-text-c1") |> render() =~
             "Every morning, before the city wakes,"

    assert has_element?(view, "#subtitle-cue-c2[data-start='4.5'][data-end='9.0']")
    assert has_element?(view, "#subtitle-check-c2", "line too long")
    assert has_element?(view, "#subtitle-check-c2", "68/42")
    assert has_element?(view, "#subtitle-checks-ok", "2 other cues")
    assert has_element?(view, "#subtitle-language-#{english.id}", "English")
    assert has_element?(view, "#subtitle-language-#{dutch.id}", "Dutch")
    assert has_element?(view, "#subtitle-editor[data-dirty='false']")
    assert has_element?(view, "#subtitle-publish.hidden")
  end

  test "edited text is published to the stored file", %{conn: conn} do
    {conn, space} = authenticated_conn(conn)
    video = video_embed_fixture(space)
    subtitle = subtitle_fixture(space, video, "en", @english)

    {:ok, view, _html} = live(conn, editor_path(video, subtitle))

    render_hook(view, "edit", %{"id" => "c3", "text" => "Nothing here is wasted."})

    assert has_element?(view, "#subtitle-editor[data-dirty='true']")
    refute has_element?(view, "#subtitle-publish.hidden")

    html = view |> element("#subtitle-publish") |> render_click()

    assert html =~ "Subtitles published"
    assert has_element?(view, "#subtitle-editor[data-dirty='false']")

    assert stored(space, video, "en") =~
             "00:00:10.000 --> 00:00:12.000\nNothing here is wasted.\n"
  end

  test "typing back the published text leaves nothing to publish", %{conn: conn} do
    {conn, space} = authenticated_conn(conn)
    video = video_embed_fixture(space)
    subtitle = subtitle_fixture(space, video, "en", @english)

    {:ok, view, _html} = live(conn, editor_path(video, subtitle))

    render_hook(view, "edit", %{"id" => "c3", "text" => "Changed"})
    render_hook(view, "edit", %{"id" => "c3", "text" => "Nothing here goes to waste."})

    assert has_element?(view, "#subtitle-editor[data-dirty='false']")
  end

  test "splitting and merging move the caret to the right cue", %{conn: conn} do
    {conn, space} = authenticated_conn(conn)
    video = video_embed_fixture(space)
    subtitle = subtitle_fixture(space, video, "en", @english)

    {:ok, view, _html} = live(conn, editor_path(video, subtitle))

    render_hook(view, "split", %{
      "id" => "c2",
      "before" => "What isn't sold at the quay ",
      "after" => "goes to the smokehouse two streets away,"
    })

    assert_push_event(view, "subtitles:cue", %{
      id: "c4",
      text: "goes to the smokehouse two streets away,",
      offset: 0,
      focus: true
    })

    assert view |> element("#subtitle-cue-text-c2") |> render() =~
             "What isn&#39;t sold at the quay</textarea>"

    assert has_element?(view, "#subtitle-cue-c4[data-selected='true'][data-end='9.0']")
    refute has_element?(view, "#subtitle-check-c2")

    render_hook(view, "merge", %{"id" => "c4", "direction" => "previous"})

    assert_push_event(view, "subtitles:cue", %{id: "c2", offset: 28, focus: true})
    refute has_element?(view, "#subtitle-cue-c4")
    assert has_element?(view, "#subtitle-cue-c2[data-selected='true'][data-end='9.0']")
    assert has_element?(view, "#subtitle-editor[data-dirty='false']")
  end

  test "undo and redo step through the changes", %{conn: conn} do
    {conn, space} = authenticated_conn(conn)
    video = video_embed_fixture(space)
    subtitle = subtitle_fixture(space, video, "en", @english)

    {:ok, view, _html} = live(conn, editor_path(video, subtitle))

    render_hook(view, "select", %{"id" => "c1"})
    view |> element("#subtitle-delete") |> render_click()
    refute has_element?(view, "#subtitle-cue-c1")

    render_hook(view, "undo", %{})
    assert has_element?(view, "#subtitle-cue-c1[data-selected='true']")
    assert has_element?(view, "#subtitle-editor[data-dirty='false']")

    render_hook(view, "redo", %{})
    refute has_element?(view, "#subtitle-cue-c1")
    assert has_element?(view, "#subtitle-cue-c2[data-selected='true']")
  end

  test "timing changes from the timeline and the panel", %{conn: conn} do
    {conn, space} = authenticated_conn(conn)
    video = video_embed_fixture(space)
    subtitle = subtitle_fixture(space, video, "en", @english)

    {:ok, view, _html} = live(conn, editor_path(video, subtitle))

    render_hook(view, "retime", %{"id" => "c3", "start" => 9.25, "end" => 60})
    assert has_element?(view, "#subtitle-cue-c3[data-selected='true'][data-start='9.25']")
    assert has_element?(view, "#subtitle-cue-c3[data-end='40.0']")

    view
    |> form("#subtitle-timing-form", %{
      "timing" => %{"start_minutes" => "0", "start_seconds" => "9,5", "end_seconds" => "13"}
    })
    |> render_change()

    assert has_element?(view, "#subtitle-cue-c3[data-start='9.5'][data-end='13.0']")
    assert has_element?(view, "#subtitle-timing-end-seconds[value='13.00']")
  end

  test "a new cue is added after the selected one", %{conn: conn} do
    {conn, space} = authenticated_conn(conn)
    video = video_embed_fixture(space)
    subtitle = subtitle_fixture(space, video, "en", @english)

    {:ok, view, _html} = live(conn, editor_path(video, subtitle))

    render_hook(view, "select", %{"id" => "c2"})
    view |> element("#subtitle-add") |> render_click()

    assert_push_event(view, "subtitles:cue", %{id: "c4", text: "", focus: true, seek: true})
    assert has_element?(view, "#subtitle-cue-c4[data-start='9.0'][data-end='10.0']")
    assert has_element?(view, "#subtitle-check-c4", "no text")
  end

  test "leaving with unpublished changes asks first", %{conn: conn} do
    {conn, space} = authenticated_conn(conn)
    video = video_embed_fixture(space)
    english = subtitle_fixture(space, video, "en", @english)
    dutch = subtitle_fixture(space, video, "nl", @dutch)

    {:ok, view, _html} = live(conn, editor_path(video, english))

    render_hook(view, "edit", %{"id" => "c1", "text" => "Changed"})
    view |> element("#subtitle-language-#{dutch.id}") |> render_click()

    assert has_element?(view, "#subtitle-leave-dialog", "Leave without publishing?")

    render_hook(view, "cancel", %{})
    assert has_element?(view, "#subtitle-cue-text-c1", "Changed")

    view |> element("#subtitle-language-#{dutch.id}") |> render_click()
    render_hook(view, "confirm", %{})

    assert_redirect(view, editor_path(video, dutch))
    assert stored(space, video, "en") == @english
  end

  test "discarding returns to the published text", %{conn: conn} do
    {conn, space} = authenticated_conn(conn)
    video = video_embed_fixture(space)
    subtitle = subtitle_fixture(space, video, "en", @english)

    {:ok, view, _html} = live(conn, editor_path(video, subtitle))

    render_hook(view, "edit", %{"id" => "c1", "text" => "Changed"})
    view |> element("#subtitle-discard") |> render_click()

    assert has_element?(view, "#subtitle-cue-text-c1", "Every morning, before the city wakes,")
    assert has_element?(view, "#subtitle-editor[data-dirty='false']")
  end

  test "the original language can be shown next to a translation", %{conn: conn} do
    {conn, space} = authenticated_conn(conn)
    video = video_embed_fixture(space, %{language: "en"})
    english = subtitle_fixture(space, video, "en", @english)
    dutch = subtitle_fixture(space, video, "nl", @dutch)

    {:ok, view, _html} = live(conn, editor_path(video, dutch))

    refute render(view) =~ "What isn&#39;t sold at the quay"
    render_hook(view, "toggle_original", %{})

    assert has_element?(view, "#subtitle-cue-c2", "What isn't sold at the quay goes to")

    {:ok, original_view, html} = live(conn, editor_path(video, english))
    refute html =~ "show original"
    render_hook(original_view, "toggle_original", %{})
    refute has_element?(original_view, "#subtitle-cue-c1", "Elke ochtend")
  end

  test "download hands over the text as it is being edited", %{conn: conn} do
    {conn, space} = authenticated_conn(conn)
    video = video_embed_fixture(space)
    subtitle = subtitle_fixture(space, video, "en", @english)

    {:ok, view, _html} = live(conn, editor_path(video, subtitle))

    render_hook(view, "edit", %{"id" => "c1", "text" => "Changed"})
    view |> element("#subtitle-download") |> render_click()

    assert_push_event(view, "subtitles:download", %{filename: "en.vtt", body: body})
    assert body =~ "00:00:01.000 --> 00:00:04.000\nChanged\n"
  end

  test "a subtitle that cannot be read sends you back to the video", %{conn: conn} do
    {conn, space} = authenticated_conn(conn)
    video = video_embed_fixture(space)
    missing = subtitle_fixture(space, video, "en", nil)

    assert {:error, {:live_redirect, %{to: to, flash: flash}}} =
             live(conn, editor_path(video, missing))

    assert to == "/videos/#{video.id}"
    assert flash["error"] =~ "can't be edited"
  end

  test "subtitles of another space cannot be opened or changed", %{conn: conn} do
    {conn, space} = authenticated_conn(conn)
    video = video_embed_fixture(space)
    subtitle_fixture(space, video, "en", @english)

    other_space = other_space_fixture()
    other_video = video_embed_fixture(other_space)
    other_subtitle = subtitle_fixture(other_space, other_video, "en", @english)

    assert {:error, {:live_redirect, %{to: "/videos/" <> _}}} =
             live(conn, "/videos/#{video.id}/subtitles/#{other_subtitle.id}")

    assert {:error, {:live_redirect, %{to: "/videos"}}} =
             live(conn, "/videos/#{other_video.id}/subtitles/#{other_subtitle.id}")

    assert stored(other_space, other_video, "en") == @english
  end

  defp editor_path(video, subtitle), do: "/videos/#{video.id}/subtitles/#{subtitle.id}"

  defp stored(space, video, language) do
    {:ok, body} =
      FlowStorageAdapterStub.get(
        Storage.bucket_for_space(space.hash, space.region || "default"),
        "#{video.hash}/subtitle_#{language}.vtt",
        space.region || "default"
      )

    body
  end

  defp subtitle_fixture(space, video, language, body) do
    key = "#{video.hash}/subtitle_#{language}.vtt"
    region = space.region || "default"

    if body do
      {:ok, _body} =
        FlowStorageAdapterStub.put_public(
          Storage.bucket_for_space(space.hash, region),
          key,
          body,
          "text/vtt",
          region
        )
    end

    %Subtitle{}
    |> Subtitle.changeset(%{
      video_id: video.asset.current_video_id,
      language: language,
      path: key
    })
    |> Repo.insert!()
  end

  defp authenticated_conn(conn) do
    email = "subtitles-#{System.unique_integer([:positive])}@example.com"
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

  defp other_space_fixture do
    {:ok, user} =
      Accounts.create_user("subtitles-#{System.unique_integer([:positive])}@example.com")

    user.current_space_membership.space
  end

  defp with_manage_host(conn) do
    case System.get_env("MAVE_MANAGE_HOST") do
      host when is_binary(host) and host != "" -> %{conn | host: host}
      _ -> conn
    end
  end

  defp video_embed_fixture(%Space{} = space, attrs \\ %{}) do
    asset =
      %Asset{}
      |> Asset.changeset(%{space_id: space.id, name: "Harbour at dawn"})
      |> Repo.insert!()

    video =
      %Video{}
      |> Video.changeset(%{
        asset_id: asset.id,
        status: "ready",
        file_name: "harbour.mp4",
        max_width: 1920,
        max_height: 1080,
        max_frame_rate: 30.0,
        max_bitrate: 10_000_000,
        duration: 40.0,
        aspect_ratio: "16/9",
        original_file_size: 100_000_000,
        language: Map.get(attrs, :language)
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
      type: :video
    })
    |> Repo.insert!()
    |> Repo.preload(asset: [:current_video])
  end

  defp unique_embed_hash do
    System.unique_integer([:positive])
    |> Integer.to_string(36)
    |> String.pad_leading(10, "0")
    |> String.slice(-10, 10)
  end
end
