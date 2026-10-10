defmodule MaveCoreWeb.Live.Dashboard.Videos.ShowTest do
  use MaveCoreWeb.ConnCase, async: false

  import Ecto.Query
  import Phoenix.LiveViewTest

  alias MaveCore.Accounts
  alias MaveCore.Assets.{Asset, AudioTrack, Subtitle, Video}
  alias MaveCore.ClickHouseRepo
  alias MaveCore.Collections.{Collection, CollectionEmbed}
  alias MaveCore.Embeds.{Embed, SettingsSerializer}
  alias MaveCore.Embeds.Events
  alias MaveCore.Flow
  alias MaveCore.Flow.Run
  alias MaveCore.Flow.StepRun
  alias MaveCore.Media.Storage
  alias MaveCore.Repo
  alias MaveCore.Spaces
  alias MaveCore.Spaces.{Key, Space}
  alias MaveCore.TestSupport.FlowStorageAdapterStub

  defmodule FailingStorage do
    def update_embed_visibility(_space, _embed_hash, _visibility, _region),
      do: {:error, :visibility_failed}
  end

  defmodule AvailablePlayback do
    def available?(_space), do: true
  end

  setup do
    old_storage_adapter = Application.get_env(:mave_core, :flow_storage_adapter)

    old_processing_player_settle_ms =
      Application.get_env(:mave_core, :processing_player_settle_ms)

    config = Application.get_env(:mave_core, MaveCore.ClickHouseRepo)
    db_name = config[:database] || "mave_metrics"

    Application.put_env(:mave_core, :flow_storage_adapter, FlowStorageAdapterStub)
    Application.put_env(:mave_core, :processing_player_settle_ms, 50)
    FlowStorageAdapterStub.reset!()
    ClickHouseRepo.query("TRUNCATE TABLE IF EXISTS #{db_name}.events")

    on_exit(fn ->
      restore_env(:flow_storage_adapter, old_storage_adapter)
      restore_env(:processing_player_settle_ms, old_processing_player_settle_ms)
      FlowStorageAdapterStub.reset!()
      ClickHouseRepo.query("TRUNCATE TABLE IF EXISTS #{db_name}.events")
    end)

    {:ok, db_name: db_name}
  end

  @tag :private_playback_ui
  test "playback visibility actions are only shown when available for the space", %{conn: conn} do
    original_adapter = Application.get_env(:mave_core, :playback_adapter)
    on_exit(fn -> restore_env(:playback_adapter, original_adapter) end)
    {conn, space} = authenticated_conn(conn)
    embed = video_embed_fixture(space, %{name: "Playback visibility"})

    for visibility <- [:public, :private], available? <- [false, true] do
      embed
      |> Ecto.Changeset.change(playback_visibility: visibility, playback_status: visibility)
      |> Repo.update!()

      Application.put_env(:mave_core, :playback_adapter, if(available?, do: AvailablePlayback))
      {:ok, view, _html} = live(conn, "/videos/#{embed.id}")

      assert has_element?(view, "#video-playback-visibility") == available?
    end
  end

  @tag :private_playback_ui
  test "private videos explain token setup and display token-aware embed code", %{conn: conn} do
    {conn, space} = authenticated_conn(conn)
    embed = video_embed_fixture(space, %{name: "Private embed setup"})

    embed
    |> Ecto.Changeset.change(playback_visibility: :private, playback_status: :private)
    |> Repo.update!()

    {:ok, view, _html} = live(conn, "/videos/#{embed.id}")
    refute has_element?(view, "#video-access-status")
    assert has_element?(view, "#private-playback-guide", "Dashboard previews work automatically")
    assert has_element?(view, "#snippet-code", "YOUR_PLAYBACK_TOKEN")
    assert has_element?(view, "#snippet-code", ~s(token="YOUR_PLAYBACK_TOKEN"))
    refute has_element?(view, "#private-playback-server-help")
    refute has_element?(view, ~s([phx-value-preview="iframe"]))

    view |> element(~s([phx-value-preview="react"])) |> render_click()
    assert has_element?(view, "#snippet-code", "token={playbackToken}")
    view |> element(~s([phx-value-preview="vue"])) |> render_click()
    assert has_element?(view, "#snippet-code", ~s(:token="playbackToken"))
    view |> element(~s([phx-value-preview="clip"])) |> render_click()

    assert has_element?(
             view,
             "#snippet-code",
             ~s(<mave-clip embed="#{space.hash}#{embed.hash}" token="YOUR_PLAYBACK_TOKEN")
           )
  end

  @tag :private_playback_ui
  test "private preview replacements update the playback session hook", %{conn: conn} do
    {conn, space} = authenticated_conn(conn)
    embed = video_embed_fixture(space, %{name: "Private settings preview"})

    embed
    |> Ecto.Changeset.change(playback_visibility: :private, playback_status: :private)
    |> Repo.update!()

    {:ok, view, _html} = live(conn, "/videos/#{embed.id}")

    player_id = fn ->
      view
      |> element("#video-components-loader")
      |> render()
      |> LazyHTML.from_fragment()
      |> LazyHTML.filter("#video-components-loader")
      |> LazyHTML.attribute("data-playback-player")
      |> List.first()
    end

    original_id = player_id.()
    assert is_binary(original_id)
    assert has_element?(view, "##{original_id} mave-player")

    view
    |> element(~s([phx-value-title="controls"][phx-value-label="big"]))
    |> render_click()

    replacement_id = player_id.()
    assert is_binary(replacement_id)
    refute replacement_id == original_id
    assert has_element?(view, ~s(##{replacement_id} mave-player[controls="big"]))
    assert has_element?(view, ~s(#video-components-loader[data-playback-status="private"]))
  end

  @tag :private_playback_ui
  test "public videos retain the ordinary embed code and iframe option", %{conn: conn} do
    {conn, space} = authenticated_conn(conn)
    embed = video_embed_fixture(space, %{name: "Public embed setup"})
    {:ok, view, _html} = live(conn, "/videos/#{embed.id}")
    refute has_element?(view, "#video-access-status")
    assert has_element?(view, ~s([phx-value-preview="iframe"]))
    refute has_element?(view, "#private-playback-guide")
    refute has_element?(view, "#snippet-code", "YOUR_PLAYBACK_TOKEN")
  end

  test "/videos/:id renders folder mode when embed type is collection", %{conn: conn} do
    {conn, space} = authenticated_conn(conn)
    folder = folder_embed_fixture(space, %{name: "Folder Mode"})
    child_video = video_embed_fixture(space, %{name: "Video Inside Folder"})
    link_embed_to_folder(folder, child_video)

    short_folder_id = folder.id
    {:ok, _view, html} = live(conn, "/videos/#{short_folder_id}")

    assert html =~ "Folder Mode"
    assert html =~ "Video Inside Folder"
    refute html =~ "drop off"
  end

  test "/videos/:id paginates folder contents like root", %{conn: conn} do
    {conn, space} = authenticated_conn(conn)
    folder = folder_embed_fixture(space, %{name: "Paged Folder"})

    embeds =
      for index <- 1..16 do
        video = video_embed_fixture(space, %{name: "Paged Child #{index}"})
        link_embed_to_folder(folder, video)
        video
      end

    oldest = hd(embeds)
    newest = List.last(embeds)

    {:ok, view, html} = live(conn, "/videos/#{folder.id}")

    assert has_element?(view, "#video-row-#{newest.id}")
    refute has_element?(view, "#video-row-#{oldest.id}")
    assert length(Regex.scan(~r/id="video-row-/, html)) == 15
    refute html =~ ~s(phx-click="next_page" disabled)

    html = render_click(view, "next_page", %{})

    assert_patch(view, "/videos/#{folder.id}?page=2")
    assert has_element?(view, "#video-row-#{oldest.id}")
    refute has_element?(view, "#video-row-#{newest.id}")
    assert length(Regex.scan(~r/id="video-row-/, html)) == 1
    assert has_element?(view, ~s(button[phx-click="next_page"][disabled]))
  end

  @tag :audio_pipeline
  test "/videos/:id renders video detail mode when embed type is video", %{conn: conn} do
    {conn, space} = authenticated_conn(conn)
    video = video_embed_fixture(space, %{name: "Video Detail Mode"})

    short_video_id = video.id
    {:ok, _view, html} = live(conn, "/videos/#{short_video_id}")

    assert html =~ "Video Detail Mode"
    assert html =~ "drop off"
    assert html =~ "Pages"
    assert html =~ ~s(style="display: block; width: 100%;)
    assert html =~ ~s(aspect-ratio: 16 / 9;)
    assert html =~ ~s(/npm/@maveio/components/+esm)
    assert html =~ ~s(/npm/@maveio/components/dist/config.js)
    assert html =~ ~s(data-component-config=)
  end

  @tag :audio_pipeline
  test "/videos/:id passes cache-busted custom thumbnail to dashboard player", %{conn: conn} do
    {conn, space} = authenticated_conn(conn)
    video = video_embed_fixture(space, %{name: "Custom Poster Player"})

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

    versioned_thumbnail_url =
      "#{thumbnail_url}?e=#{DateTime.to_unix(inserted_at, :microsecond)}"

    {:ok, _view, html} = live(conn, "/videos/#{video.id}")

    assert html =~ ~s(<mave-player embed="#{space.hash}#{video.hash}")
    assert html =~ ~s(poster="#{versioned_thumbnail_url}")
    assert html =~ versioned_thumbnail_url
  end

  @tag :poster_upload
  test "poster processing remains visible until a delayed conversion completes", %{conn: conn} do
    {conn, space} = authenticated_conn(conn)
    embed = video_embed_fixture(space, %{name: "Delayed Poster"})
    {:ok, view, _html} = live(conn, "/videos/#{embed.id}")
    start_poster_upload(view)
    ref = poster_upload_ref(view)
    assert has_element?(view, "#poster-processing")

    # Pass the former four-poll window without waiting for wall-clock timers.
    send(view.pid, {:reload_poster, embed.id, ref, 115})
    assert has_element?(view, "#poster-processing")

    materialize_custom_poster(embed, space)
    send(view.pid, {:reload_poster, embed.id, ref, 114})
    refute has_element?(view, "#poster-processing")
    assert has_element?(view, ~s(mave-player[poster*="thumbnail.jpg"]))
    assert has_element?(view, "#settings-poster-upload-form")
  end

  @tag :poster_upload
  test "an existing poster and unrelated updates do not finish a replacement upload", %{
    conn: conn
  } do
    {conn, space} = authenticated_conn(conn)
    embed = video_embed_fixture(space, %{name: "Replacing Poster"})
    materialize_custom_poster(embed, space)
    {:ok, view, _html} = live(conn, "/videos/#{embed.id}")
    start_poster_upload(view)
    ref = poster_upload_ref(view)
    assert has_element?(view, "#poster-processing")

    send(view.pid, {:reload_poster, embed.id, ref, 115})
    assert has_element?(view, "#poster-processing")
    send(view.pid, {MaveCoreWeb.Dashboard.Videos.VideoSettingsComponent, :audio_tracks_updated})
    assert has_element?(view, "#poster-processing")

    materialize_custom_poster(embed, space)
    send(view.pid, {:reload_poster, embed.id, ref, 114})
    refute has_element?(view, "#poster-processing")
  end

  @tag :poster_upload
  test "a poster completing before upload progress reaches 100 percent is recognized", %{
    conn: conn
  } do
    {conn, space} = authenticated_conn(conn)
    embed = video_embed_fixture(space, %{name: "Fast Poster"})
    {:ok, view, _html} = live(conn, "/videos/#{embed.id}")
    send(view.pid, {MaveCoreWeb.Dashboard.Videos.VideoSettingsComponent, :poster_upload_started})
    _ = render(view)
    materialize_custom_poster(embed, space)
    send(view.pid, {MaveCoreWeb.Dashboard.Videos.VideoSettingsComponent, :audio_tracks_updated})
    _ = render(view)
    ref = poster_upload_ref(view)

    send(view.pid, {MaveCoreWeb.Dashboard.Videos.VideoSettingsComponent, :poster_uploaded})
    send(view.pid, {:reload_poster, embed.id, ref, 119})
    refute has_element?(view, "#poster-processing")
    refute has_element?(view, "#flash-error")
  end

  @tag :poster_upload
  test "poster timeout stops the spinner and an old timer cannot cancel a retry", %{conn: conn} do
    {conn, space} = authenticated_conn(conn)
    embed = video_embed_fixture(space, %{name: "Failed Poster"})
    {:ok, view, _html} = live(conn, "/videos/#{embed.id}")
    start_poster_upload(view)
    old_ref = poster_upload_ref(view)
    assert has_element?(view, "#poster-processing")

    send(view.pid, {:reload_poster, embed.id, old_ref, 0})
    refute has_element?(view, "#poster-processing")
    assert has_element?(view, "#flash-error")
    assert has_element?(view, "#settings-poster-upload-form")

    start_poster_upload(view)
    send(view.pid, {:reload_poster, embed.id, old_ref, 0})
    assert has_element?(view, "#poster-processing")
  end

  defp start_poster_upload(view) do
    send(view.pid, {MaveCoreWeb.Dashboard.Videos.VideoSettingsComponent, :poster_upload_started})
    send(view.pid, {MaveCoreWeb.Dashboard.Videos.VideoSettingsComponent, :poster_uploaded})
    _ = render(view)
  end

  defp poster_upload_ref(view), do: :sys.get_state(view.pid).socket.assigns.poster_upload.ref

  defp materialize_custom_poster(embed, space) do
    embed = Repo.preload(embed, :asset)
    video_id = MaveCore.LegacyShortUUID.dump!(embed.asset.current_video_id)

    Repo.delete_all(
      from(r in "renditions", where: r.video_id == ^video_id and r.type == "custom_thumbnail")
    )

    now = DateTime.utc_now() |> DateTime.truncate(:second)

    Repo.insert_all("renditions", [
      %{
        id: MaveCore.LegacyShortUUID.dump!(Ecto.UUID.generate()),
        video_id: video_id,
        rendition_key: "#{embed.hash}/thumbnail.jpg",
        type: "custom_thumbnail",
        container: "jpg",
        progress: 100.0,
        file_size: 1_000,
        inserted_at: now,
        updated_at: now
      }
    ])

    {:ok, _} =
      MaveCore.Embeds.update_settings(embed, %{
        poster: :upload,
        external_poster:
          SettingsSerializer.storage_object_url(
            "space-#{space.hash}",
            "#{embed.hash}/thumbnail.jpg"
          )
      })
  end

  @tag :audio_pipeline
  test "/videos/:id snippet uses legacy thumbnail and clip poster assets", %{conn: conn} do
    {conn, space} = authenticated_conn(conn)

    video = video_embed_fixture(space, %{name: "Legacy Snippet Assets"})

    assert {:ok, video} =
             MaveCore.Embeds.update_settings(video, %{
               controls_enabled: false,
               aspect_ratio_enabled: false,
               width: "720px",
               height: "405px",
               autoplay_enabled: true,
               autoplay: :always,
               loop_enabled: true
             })

    video = Repo.preload(video, asset: [:current_video])

    custom_thumbnail_inserted_at = ~U[2026-01-02 03:04:05Z]

    Repo.insert_all("renditions", [
      %{
        id: MaveCore.LegacyShortUUID.dump!(Ecto.UUID.generate()),
        video_id: MaveCore.LegacyShortUUID.dump!(video.asset.current_video_id),
        rendition_key: "#{video.hash}/thumbnail.jpg",
        type: "custom_thumbnail",
        codec: "jpg",
        container: "jpg",
        size: nil,
        progress: 100.0,
        file_size: 1_000,
        inserted_at: custom_thumbnail_inserted_at,
        updated_at: custom_thumbnail_inserted_at
      }
    ])

    {:ok, view, html} = live(conn, "/videos/#{video.id}")
    text = highlighted_text(html)

    assert text =~
             ~s(<mave-playerembed="#{space.hash}#{video.hash}"controls="none"width="720px"height="405px"autoplay="always"loopstyle=)

    assert text =~
             "background:center/containno-repeaturl(https://space-#{space.hash}.video-dns.com/#{video.hash}/thumbnail.jpg?e=#{DateTime.to_unix(custom_thumbnail_inserted_at, :microsecond)});"

    refute html =~ ~s(class="mave-snippet-attr">background)
    refute html =~ ~s(class="mave-snippet-attr">aspect-ratio)

    html =
      view
      |> element(~s([phx-value-preview="clip"]))
      |> render_click()

    text = highlighted_text(html)

    assert text =~ ~s(<mave-clipembed="#{space.hash}#{video.hash}"style=)
    refute text =~ ~s(<mave-clipembed="#{space.hash}#{video.hash}"controls=)

    assert text =~
             "background:center/coverno-repeaturl(https://space-#{space.hash}.video-dns.com/#{video.hash}/poster.jpg);"

    html =
      view
      |> element(~s([phx-value-preview="iframe"]))
      |> render_click()

    assert highlighted_text(html) =~
             ~s(width="640"height="360"frameborder="0"scrolling="no"allowfullscreen)

    assert html =~ ~s(class="mave-snippet-tag">iframe)
    assert html =~ ~s(class="mave-snippet-attr">src)

    html =
      view
      |> element(~s([phx-value-preview="react"]))
      |> render_click()

    assert highlighted_text(html) =~
             ~s(<Playerembed="#{space.hash}#{video.hash}"controls="none"width="720px"height="405px"autoplay="always"loop></Player>)

    html =
      view
      |> element(~s([phx-value-preview="vue"]))
      |> render_click()

    assert highlighted_text(html) =~
             ~s(<Playerembed="#{space.hash}#{video.hash}"controls="none"width="720px"height="405px"autoplay="always"loop></Player>)
  end

  test "/videos/:id snippet omits component config when bundle defaults match production", %{
    conn: conn
  } do
    with_default_component_runtime(fn ->
      {conn, space} = authenticated_conn(conn)
      video = video_embed_fixture(space, %{name: "Default Runtime Snippet"})

      {:ok, view, html} = live(conn, "/videos/#{video.id}")
      text = highlighted_text(html)

      refute text =~ "configureMave"
      refute text =~ "/dist/config.js"
      refute text =~ "crossorigin"

      assert text =~
               ~S|<scripttype="module"src="https://cdn.video-dns.com/npm/@maveio/components/+esm"></script>|

      html =
        view
        |> element(~s([phx-value-preview="react"]))
        |> render_click()

      text = highlighted_text(html)

      refute text =~ "configureMave"

      assert text =~
               ~S|const{Player}=awaitimport("https://cdn.video-dns.com/npm/@maveio/components/dist/react.js");|

      html =
        view
        |> element(~s([phx-value-preview="vue"]))
        |> render_click()

      text = highlighted_text(html)

      refute text =~ "configureMave"

      assert text =~
               ~S|const{Player}=awaitimport("https://cdn.video-dns.com/npm/@maveio/components/dist/vue.js");|
    end)
  end

  test "/videos/:id can switch into and out of replace mode with the upload panel", %{conn: conn} do
    {conn, space} = authenticated_conn(conn)
    video = video_embed_fixture(space, %{name: "Replace Flow"})

    {:ok, view, html} = live(conn, "/videos/#{video.id}")

    assert html =~ "<mave-player"
    refute html =~ "mave-upload"
    assert has_element?(view, "#video-actions")

    render_click(element(view, "#video-actions .cursor-pointer", "replace"))
    html = render(view)

    assert html =~ "cancel replace"
    assert html =~ "mave-upload"
    refute html =~ "<mave-player"

    assert %Key{purpose: :dashboard_uploads} =
             Repo.get_by(Key, space_id: space.id, purpose: :dashboard_uploads)

    assert [] == Spaces.list_user_managed_keys(space)

    render_click(element(view, "#video-actions .cursor-pointer", "cancel replace"))
    html = render(view)

    assert html =~ "replace"
    assert html =~ "<mave-player"
    refute html =~ "mave-upload"
  end

  test "/videos/:id renders upload shell for videos without a current file", %{conn: conn} do
    {conn, space} = authenticated_conn(conn)
    video = placeholder_video_embed_fixture(space, %{name: "Upload Placeholder"})

    {:ok, _view, html} = live(conn, "/videos/#{video.id}")

    assert html =~ "Upload Placeholder"
    assert html =~ "drop video here"
    assert html =~ "mave-upload"
    assert html =~ "drop off"
    assert html =~ "pages"
    assert html =~ "Not enough data yet"
    assert html =~ "No pages linked yet"
  end

  test "/videos/:id shows the detail processing state while the current video is still uploading",
       %{
         conn: conn
       } do
    {conn, space} = authenticated_conn(conn)
    video = placeholder_video_embed_fixture(space, %{name: "Uploading Placeholder"})

    current_video =
      %Video{}
      |> Video.changeset(%{
        asset_id: video.asset_id,
        status: "uploading",
        file_name: "Uploading Placeholder.mp4",
        original_file_size: 12_345
      })
      |> Repo.insert!()

    Repo.get!(Asset, video.asset_id)
    |> Ecto.Changeset.change(current_video_id: current_video.id)
    |> Repo.update!()

    {:ok, template} =
      Flow.create_template(%{
        "slug" => "uploading-placeholder-#{System.unique_integer([:positive])}",
        "name" => "Uploading Placeholder"
      })

    {:ok, version} =
      Flow.create_version(template.id, %{
        "definition" => %{
          "steps" => [
            %{"id" => "source", "type" => "source.resolve", "name" => "Resolve Source"}
          ]
        }
      })

    {:ok, run} =
      %Run{}
      |> Run.changeset(%{
        flow_template_id: template.id,
        flow_version_id: version.id,
        status: "running",
        input: %{"space_hash" => space.hash, "embed_hash" => video.hash},
        context: %{}
      })
      |> Repo.insert()

    %StepRun{}
    |> StepRun.changeset(%{
      flow_run_id: run.id,
      step_id: "upload_original",
      step_type: "asset.upload_original",
      status: "succeeded",
      attempt: 1,
      execution_metadata: %{"processing_player" => %{"ready" => true}},
      output: %{
        "bucket" => "space-#{space.hash}",
        "original_key" => "#{video.hash}/original"
      }
    })
    |> Repo.insert!()

    {:ok, _view, html} = live(conn, "/videos/#{video.id}")

    assert html =~ "Uploading Placeholder"
    assert html =~ ~s(phx-value-tab="info")
    refute html =~ "drop video here"
    refute html =~ "video-upload-bridge-detail"
    assert html =~ "drop off"
    assert html =~ "pages"
  end

  test "/videos/:id keeps failed processing videos out of the upload state", %{conn: conn} do
    {conn, space} = authenticated_conn(conn)
    video = placeholder_video_embed_fixture(space, %{name: "Failed HLS Processing"})

    current_video =
      %Video{}
      |> Video.changeset(%{
        asset_id: video.asset_id,
        status: "preparing",
        file_name: "failed-hls-processing.mp4",
        original_file_size: 12_345
      })
      |> Repo.insert!()

    Repo.get!(Asset, video.asset_id)
    |> Ecto.Changeset.change(current_video_id: current_video.id)
    |> Repo.update!()

    {:ok, template} =
      Flow.create_template(%{
        "slug" => "failed-hls-processing-#{System.unique_integer([:positive])}",
        "name" => "Failed HLS Processing"
      })

    {:ok, version} =
      Flow.create_version(template.id, %{
        "definition" => %{
          "steps" => [
            %{"id" => "hls_h264_sd", "type" => "media.package_hls_variant", "name" => "480p HLS"}
          ]
        }
      })

    {:ok, run} =
      %Run{}
      |> Run.changeset(%{
        flow_template_id: template.id,
        flow_version_id: version.id,
        status: "failed",
        input: %{"space_hash" => space.hash, "embed_hash" => video.hash},
        context: %{},
        error: "one or more required steps failed"
      })
      |> Repo.insert()

    %StepRun{}
    |> StepRun.changeset(%{
      flow_run_id: run.id,
      step_id: "upload_original",
      step_type: "asset.upload_original",
      status: "succeeded",
      attempt: 1,
      execution_metadata: %{"processing_player" => %{"ready" => true}},
      output: %{
        "bucket" => "space-#{space.hash}",
        "original_key" => "#{video.hash}/original"
      }
    })
    |> Repo.insert!()

    failed_hls_step =
      %StepRun{}
      |> StepRun.changeset(%{
        flow_run_id: run.id,
        step_id: "hls_h264_sd",
        step_type: "media.package_hls_variant",
        status: "failed",
        attempt: 1,
        error: "hls upload failed"
      })
      |> Repo.insert!()

    %StepRun{}
    |> StepRun.changeset(%{
      flow_run_id: run.id,
      step_id: "video_h264_sd",
      step_type: "media.transcode_video",
      status: "succeeded",
      attempt: 1,
      output: %{
        "status" => "ok",
        "renditions" => [
          %{
            "id" => Ecto.UUID.generate(),
            "type" => "video",
            "container" => "mp4",
            "codec" => "h264",
            "size" => "sd",
            "progress" => 100
          }
        ]
      }
    })
    |> Repo.insert!()

    {:ok, view, html} = live(conn, "/videos/#{video.id}")

    assert html =~ "<mave-player"
    assert html =~ "Failed"
    refute html =~ "drop video here"
    refute html =~ "video-upload-bridge-detail"

    failed_rendition_selector = "#rendition_pending-#{failed_hls_step.id}"
    assert has_element?(view, "#{failed_rendition_selector} .rendition-status-failed")
    refute has_element?(view, "#{failed_rendition_selector} .rendition-activity-notch")

    render_click(element(view, ~s([phx-value-tab="info"])))
    html = render(view)

    assert html =~ ">videos<"
    assert html =~ "HLS"
    assert html =~ "H.264"
    assert html =~ "480p"
    assert html =~ "from-red-400"
  end

  test "/videos/:id keeps persisted preparing videos out of upload mode without a preview", %{
    conn: conn
  } do
    {conn, space} = authenticated_conn(conn)
    video = placeholder_video_embed_fixture(space, %{name: "Preparing Without Preview"})

    current_video =
      %Video{}
      |> Video.changeset(%{
        asset_id: video.asset_id,
        status: "preparing",
        file_name: "preparing-without-preview.mp4",
        original_file_size: 12_345
      })
      |> Repo.insert!()

    Repo.get!(Asset, video.asset_id)
    |> Ecto.Changeset.change(current_video_id: current_video.id)
    |> Repo.update!()

    {:ok, _view, html} = live(conn, "/videos/#{video.id}")

    assert html =~ "Preparing Without Preview"
    refute html =~ "drop video here"
    refute html =~ "video-upload-bridge-detail"
    refute html =~ ~s(id="video-settings")
  end

  test "/videos/:id shows queued and encoding renditions while processing", %{conn: conn} do
    {conn, space} = authenticated_conn(conn)
    video = placeholder_video_embed_fixture(space, %{name: "Processing Detail"})

    current_video =
      %Video{}
      |> Video.changeset(%{
        asset_id: video.asset_id,
        status: "uploading",
        file_name: "Processing Detail.mp4",
        original_file_size: 12_345
      })
      |> Repo.insert!()

    Repo.get!(Asset, video.asset_id)
    |> Ecto.Changeset.change(current_video_id: current_video.id)
    |> Repo.update!()

    {:ok, template} =
      Flow.create_template(%{
        "slug" => "show-processing-#{System.unique_integer([:positive])}",
        "name" => "Show Processing"
      })

    {:ok, version} =
      Flow.create_version(template.id, %{
        "definition" => %{
          "steps" => [
            %{"id" => "source", "type" => "source.resolve", "name" => "Resolve Source"}
          ]
        }
      })

    {:ok, run} =
      %Run{}
      |> Run.changeset(%{
        flow_template_id: template.id,
        flow_version_id: version.id,
        status: "running",
        input: %{"space_hash" => space.hash, "embed_hash" => video.hash},
        context: %{}
      })
      |> Repo.insert()

    %StepRun{}
    |> StepRun.changeset(%{
      flow_run_id: run.id,
      step_id: "upload_original",
      step_type: "asset.upload_original",
      status: "succeeded",
      attempt: 1,
      execution_metadata: %{"processing_player" => %{"ready" => true}},
      output: %{
        "bucket" => "space-#{space.hash}",
        "original_key" => "#{video.hash}/original"
      }
    })
    |> Repo.insert!()

    %StepRun{}
    |> StepRun.changeset(%{
      flow_run_id: run.id,
      step_id: "video_h264_sd",
      step_type: "media.transcode_video",
      status: "executing",
      attempt: 1,
      input: %{"params" => %{"codec" => "h264", "size" => "sd", "container" => "mp4"}}
    })
    |> Repo.insert!()

    %StepRun{}
    |> StepRun.changeset(%{
      flow_run_id: run.id,
      step_id: "hls_h264_sd",
      step_type: "media.package_hls_variant",
      status: "queued",
      attempt: 0,
      input: %{"params" => %{"codec" => "h264", "size" => "sd"}}
    })
    |> Repo.insert!()

    {:ok, view, html} = live(conn, "/videos/#{video.id}")

    assert html =~ ~s(phx-value-tab="info")
    refute html =~ ~s(id="rendition_pending-video_h264_sd")

    render_click(element(view, ~s([phx-value-tab="info"])))
    html = render(view)

    assert html =~ ">videos<"
    assert html =~ "HLS"
    assert html =~ "H.264"
    assert html =~ "480p"
    assert length(Regex.scan(~r/>\s*480p\s*</, html)) == 2
  end

  test "/videos/:id shows processing before original or rendition is playable", %{
    conn: conn
  } do
    {conn, space} = authenticated_conn(conn)
    video = placeholder_video_embed_fixture(space, %{name: "Wait For Original"})

    current_video =
      %Video{}
      |> Video.changeset(%{
        asset_id: video.asset_id,
        status: "preparing",
        file_name: "Wait For Original.mp4",
        original_file_size: 12_345
      })
      |> Repo.insert!()

    Repo.get!(Asset, video.asset_id)
    |> Ecto.Changeset.change(current_video_id: current_video.id)
    |> Repo.update!()

    {:ok, template} =
      Flow.create_template(%{
        "slug" => "wait-for-original-#{System.unique_integer([:positive])}",
        "name" => "Wait For Original"
      })

    {:ok, version} =
      Flow.create_version(template.id, %{
        "definition" => %{
          "steps" => [
            %{"id" => "source", "type" => "source.resolve", "name" => "Resolve Source"},
            %{
              "id" => "upload_original",
              "type" => "asset.upload_original",
              "name" => "Upload Original",
              "depends_on" => ["source"]
            }
          ]
        }
      })

    {:ok, run} =
      %Run{}
      |> Run.changeset(%{
        flow_template_id: template.id,
        flow_version_id: version.id,
        status: "running",
        input: %{
          "space_hash" => space.hash,
          "embed_hash" => video.hash,
          "input_url" => "https://example.com/wait-for-media.mp4"
        },
        context: %{}
      })
      |> Repo.insert()

    %StepRun{}
    |> StepRun.changeset(%{
      flow_run_id: run.id,
      step_id: "upload_original",
      step_type: "asset.upload_original",
      status: "succeeded",
      attempt: 1,
      output: %{
        "bucket" => "space-#{space.hash}",
        "original_key" => "#{video.hash}/original"
      }
    })
    |> Repo.insert!()

    {:ok, _view, html} = live(conn, "/videos/#{video.id}")

    refute html =~ "drop video here"
    refute html =~ "mave-upload"
    refute html =~ ~s(id="video-settings")
  end

  test "/videos/:id mounts the player during processing when original playback is available", %{
    conn: conn
  } do
    {conn, space} = authenticated_conn(conn)
    video = placeholder_video_embed_fixture(space, %{name: "Processing Player Ready"})

    current_video =
      %Video{}
      |> Video.changeset(%{
        asset_id: video.asset_id,
        status: "uploading",
        file_name: "processing-player-ready.mp4",
        original_file_size: 12_345
      })
      |> Repo.insert!()

    Repo.get!(Asset, video.asset_id)
    |> Ecto.Changeset.change(current_video_id: current_video.id)
    |> Repo.update!()

    {:ok, template} =
      Flow.create_template(%{
        "slug" => "show-processing-player-#{System.unique_integer([:positive])}",
        "name" => "Show Processing Player"
      })

    {:ok, version} =
      Flow.create_version(template.id, %{
        "definition" => %{
          "steps" => [
            %{"id" => "source", "type" => "source.resolve", "name" => "Resolve Source"}
          ]
        }
      })

    {:ok, run} =
      %Run{}
      |> Run.changeset(%{
        flow_template_id: template.id,
        flow_version_id: version.id,
        status: "running",
        input: %{"space_hash" => space.hash, "embed_hash" => video.hash},
        context: %{}
      })
      |> Repo.insert()

    %StepRun{}
    |> StepRun.changeset(%{
      flow_run_id: run.id,
      step_id: "upload_original",
      step_type: "asset.upload_original",
      status: "succeeded",
      attempt: 1,
      execution_metadata: %{"processing_player" => %{"ready" => true}},
      output: %{
        "bucket" => "space-#{space.hash}",
        "original_key" => "#{video.hash}/original"
      }
    })
    |> Repo.insert!()

    {:ok, _view, html} = live(conn, "/videos/#{video.id}")

    assert html =~ "<mave-player"
    refute html =~ "processing..."
  end

  test "/videos/:id mounts the player when an H264 rendition finishes before the original", %{
    conn: conn
  } do
    {conn, space} = authenticated_conn(conn)
    video = placeholder_video_embed_fixture(space, %{name: "Early H264 Player"})

    current_video =
      %Video{}
      |> Video.changeset(%{
        asset_id: video.asset_id,
        status: "preparing",
        file_name: "early-h264-player.mp4",
        original_file_size: 12_345
      })
      |> Repo.insert!()

    Repo.get!(Asset, video.asset_id)
    |> Ecto.Changeset.change(current_video_id: current_video.id)
    |> Repo.update!()

    {:ok, template} =
      Flow.create_template(%{
        "slug" => "early-h264-player-#{System.unique_integer([:positive])}",
        "name" => "Early H264 Player"
      })

    {:ok, version} =
      Flow.create_version(template.id, %{
        "definition" => %{
          "steps" => [
            %{
              "id" => "video_h264_ladder",
              "type" => "media.transcode_h264_ladder",
              "name" => "H264 Ladder"
            }
          ]
        }
      })

    {:ok, run} =
      %Run{}
      |> Run.changeset(%{
        flow_template_id: template.id,
        flow_version_id: version.id,
        status: "running",
        input: %{
          "space_hash" => space.hash,
          "embed_hash" => video.hash,
          "input_url" => "https://example.com/early-h264.mp4"
        },
        context: %{}
      })
      |> Repo.insert()

    %StepRun{}
    |> StepRun.changeset(%{
      flow_run_id: run.id,
      step_id: "video_h264_ladder",
      step_type: "media.transcode_h264_ladder",
      status: "succeeded",
      attempt: 1,
      execution_metadata: %{"processing_player" => %{"ready" => true}},
      output: %{
        "status" => "ok",
        "renditions" => [
          %{
            "type" => "video",
            "codec" => "h264",
            "container" => "mp4",
            "progress" => 100.0,
            "rendition_key" => "#{video.hash}/h264_sd.mp4"
          }
        ]
      }
    })
    |> Repo.insert!()

    {:ok, _view, html} = live(conn, "/videos/#{video.id}")

    assert html =~ "<mave-player"
    refute html =~ "processing..."
  end

  test "/videos/:id keeps the processing player visible after a refresh", %{conn: conn} do
    Application.put_env(:mave_core, :processing_player_settle_ms, 10_000)

    {conn, space} = authenticated_conn(conn)
    video = placeholder_video_embed_fixture(space, %{name: "Refresh Processing Player"})

    current_video =
      %Video{}
      |> Video.changeset(%{
        asset_id: video.asset_id,
        status: "uploading",
        file_name: "refresh-processing-player.mp4",
        original_file_size: 12_345
      })
      |> Repo.insert!()

    Repo.get!(Asset, video.asset_id)
    |> Ecto.Changeset.change(current_video_id: current_video.id)
    |> Repo.update!()

    {:ok, template} =
      Flow.create_template(%{
        "slug" => "refresh-processing-player-#{System.unique_integer([:positive])}",
        "name" => "Refresh Processing Player"
      })

    {:ok, version} =
      Flow.create_version(template.id, %{
        "definition" => %{
          "steps" => [
            %{"id" => "source", "type" => "source.resolve", "name" => "Resolve Source"}
          ]
        }
      })

    {:ok, run} =
      %Run{}
      |> Run.changeset(%{
        flow_template_id: template.id,
        flow_version_id: version.id,
        status: "running",
        input: %{"space_hash" => space.hash, "embed_hash" => video.hash},
        context: %{}
      })
      |> Repo.insert()

    %StepRun{}
    |> StepRun.changeset(%{
      flow_run_id: run.id,
      step_id: "upload_original",
      step_type: "asset.upload_original",
      status: "succeeded",
      attempt: 1,
      execution_metadata: %{"processing_player" => %{"ready" => true}},
      output: %{
        "bucket" => "space-#{space.hash}",
        "original_key" => "#{video.hash}/original"
      }
    })
    |> Repo.insert!()

    path = "/videos/#{video.id}"

    {:ok, _view, html} = live(conn, path)
    assert html =~ "<mave-player"

    {:ok, _reloaded_view, reloaded_html} = live(conn, path)
    assert reloaded_html =~ "<mave-player"
    refute reloaded_html =~ "processing..."
  end

  test "/videos/:id updates from processing to ready on embed pubsub events", %{conn: conn} do
    {conn, space} = authenticated_conn(conn)
    video = placeholder_video_embed_fixture(space, %{name: "PubSub Ready"})

    current_video =
      %Video{}
      |> Video.changeset(%{
        asset_id: video.asset_id,
        status: "uploading",
        file_name: "pubsub-ready.mp4",
        original_file_size: 12_345
      })
      |> Repo.insert!()

    Repo.get!(Asset, video.asset_id)
    |> Ecto.Changeset.change(current_video_id: current_video.id)
    |> Repo.update!()

    {:ok, template} =
      Flow.create_template(%{
        "slug" => "pubsub-ready-#{System.unique_integer([:positive])}",
        "name" => "PubSub Ready"
      })

    {:ok, version} =
      Flow.create_version(template.id, %{
        "definition" => %{
          "steps" => [
            %{"id" => "source", "type" => "source.resolve", "name" => "Resolve Source"}
          ]
        }
      })

    {:ok, run} =
      %Run{}
      |> Run.changeset(%{
        flow_template_id: template.id,
        flow_version_id: version.id,
        status: "running",
        input: %{"space_hash" => space.hash, "embed_hash" => video.hash},
        context: %{}
      })
      |> Repo.insert()

    %StepRun{}
    |> StepRun.changeset(%{
      flow_run_id: run.id,
      step_id: "upload_original",
      step_type: "asset.upload_original",
      status: "succeeded",
      attempt: 1,
      output: %{
        "bucket" => "space-#{space.hash}",
        "original_key" => "#{video.hash}/original"
      }
    })
    |> Repo.insert!()

    {:ok, view, html} = live(conn, "/videos/#{video.id}")

    refute html =~ "drop video here"
    refute html =~ ~s(id="video-settings")

    current_video
    |> Video.changeset(%{status: "ready"})
    |> Repo.update!()

    assert {:ok, %Embed{asset: %{current_video: %{status: "ready"}}}} =
             MaveCore.Embeds.resolve_dashboard_embed(space, video.id)

    Events.broadcast_updated(space.id, video.id, %{"status" => "ready"})
    assert_eventually(fn -> render(view) =~ "<mave-player" end)
    refute render(view) =~ "drop video here"
    assert render(view) =~ ~s(id="video-settings")

    Events.broadcast_updated(space.id, video.id, %{"phase" => "processing"})
    assert_eventually(fn -> render(view) =~ "<mave-player" end)

    refute render(view) =~
             "Preview becomes available once the original or first video rendition is ready."
  end

  test "/videos/:id keeps the processing player mounted once original playback is available", %{
    conn: conn
  } do
    {conn, space} = authenticated_conn(conn)
    video = placeholder_video_embed_fixture(space, %{name: "Latched Processing Player"})

    current_video =
      %Video{}
      |> Video.changeset(%{
        asset_id: video.asset_id,
        status: "uploading",
        file_name: "latched-processing-player.mp4",
        original_file_size: 12_345
      })
      |> Repo.insert!()

    Repo.get!(Asset, video.asset_id)
    |> Ecto.Changeset.change(current_video_id: current_video.id)
    |> Repo.update!()

    {:ok, template} =
      Flow.create_template(%{
        "slug" => "latched-processing-player-#{System.unique_integer([:positive])}",
        "name" => "Latched Processing Player"
      })

    {:ok, version} =
      Flow.create_version(template.id, %{
        "definition" => %{
          "steps" => [
            %{"id" => "source", "type" => "source.resolve", "name" => "Resolve Source"}
          ]
        }
      })

    {:ok, run} =
      %Run{}
      |> Run.changeset(%{
        flow_template_id: template.id,
        flow_version_id: version.id,
        status: "running",
        input: %{"space_hash" => space.hash, "embed_hash" => video.hash},
        context: %{}
      })
      |> Repo.insert()

    processing_step =
      %StepRun{}
      |> StepRun.changeset(%{
        flow_run_id: run.id,
        step_id: "upload_original",
        step_type: "asset.upload_original",
        status: "succeeded",
        attempt: 1,
        execution_metadata: %{"processing_player" => %{"ready" => true}},
        output: %{
          "bucket" => "space-#{space.hash}",
          "original_key" => "#{video.hash}/original"
        }
      })
      |> Repo.insert!()

    {:ok, view, html} = live(conn, "/videos/#{video.id}")

    assert html =~ "<mave-player"

    processing_step
    |> StepRun.changeset(%{execution_metadata: %{}})
    |> Repo.update!()

    Events.broadcast_updated(space.id, video.id, %{"phase" => "processing"})

    assert_eventually(fn -> render(view) =~ "<mave-player" end)

    refute render(view) =~
             "Preview becomes available once the original or first video rendition is ready."
  end

  test "/videos/:id does not show queued audio or image renditions before they exist", %{
    conn: conn
  } do
    {conn, space} = authenticated_conn(conn)
    video = placeholder_video_embed_fixture(space, %{name: "No Early Audio Image"})

    current_video =
      %Video{}
      |> Video.changeset(%{
        asset_id: video.asset_id,
        status: "uploading",
        file_name: "no-early-audio-image.mp4",
        original_file_size: 12_345
      })
      |> Repo.insert!()

    Repo.get!(Asset, video.asset_id)
    |> Ecto.Changeset.change(current_video_id: current_video.id)
    |> Repo.update!()

    {:ok, template} =
      Flow.create_template(%{
        "slug" => "show-pending-non-video-#{System.unique_integer([:positive])}",
        "name" => "Show Pending Non Video"
      })

    {:ok, version} =
      Flow.create_version(template.id, %{
        "definition" => %{
          "steps" => [
            %{"id" => "source", "type" => "source.resolve", "name" => "Resolve Source"}
          ]
        }
      })

    {:ok, run} =
      %Run{}
      |> Run.changeset(%{
        flow_template_id: template.id,
        flow_version_id: version.id,
        status: "running",
        input: %{"space_hash" => space.hash, "embed_hash" => video.hash},
        context: %{}
      })
      |> Repo.insert()

    %StepRun{}
    |> StepRun.changeset(%{
      flow_run_id: run.id,
      step_id: "upload_original",
      step_type: "asset.upload_original",
      status: "succeeded",
      attempt: 1,
      execution_metadata: %{"processing_player" => %{"ready" => true}},
      output: %{
        "bucket" => "space-#{space.hash}",
        "original_key" => "#{video.hash}/original"
      }
    })
    |> Repo.insert!()

    %StepRun{}
    |> StepRun.changeset(%{
      flow_run_id: run.id,
      step_id: "transcode_audio",
      step_type: "media.transcode_audio",
      status: "queued",
      attempt: 0,
      input: %{"params" => %{"codec" => "mp3", "container" => "mp3"}}
    })
    |> Repo.insert!()

    %StepRun{}
    |> StepRun.changeset(%{
      flow_run_id: run.id,
      step_id: "poster_frame",
      step_type: "media.extract_frame",
      status: "queued",
      attempt: 0,
      input: %{"params" => %{"codec" => "jpg", "role" => "poster"}}
    })
    |> Repo.insert!()

    {:ok, view, _html} = live(conn, "/videos/#{video.id}")

    render_click(element(view, ~s([phx-value-tab="info"])))
    html = render(view)

    refute html =~ ">audio<"
    refute html =~ ">images<"
    refute html =~ "Poster"
    refute html =~ "MP3"
  end

  test "/videos/:id hides flow details from the info panel", %{conn: conn} do
    {conn, space} = authenticated_conn(conn)
    video = video_embed_fixture(space, %{name: "Hidden Processing Panel"})

    {:ok, template} =
      Flow.create_template(%{
        "slug" => "hidden-processing-panel-#{System.unique_integer([:positive])}",
        "name" => "Hidden Processing Panel"
      })

    {:ok, version} =
      Flow.create_version(template.id, %{
        "definition" => %{
          "steps" => [
            %{"id" => "source", "type" => "source.resolve", "name" => "Resolve Source"},
            %{
              "id" => "manifest",
              "type" => "manifest.build",
              "name" => "Build Manifest",
              "depends_on" => ["source"]
            }
          ]
        }
      })

    {:ok, run} =
      %Run{}
      |> Run.changeset(%{
        flow_template_id: template.id,
        flow_version_id: version.id,
        status: "running",
        input: %{"space_hash" => space.hash, "embed_hash" => video.hash},
        context: %{}
      })
      |> Repo.insert()

    %StepRun{}
    |> StepRun.changeset(%{
      flow_run_id: run.id,
      step_id: "source",
      step_type: "source.resolve",
      status: "succeeded",
      attempt: 1,
      input: %{},
      completed_at: DateTime.utc_now() |> DateTime.truncate(:microsecond)
    })
    |> Repo.insert!()

    %StepRun{}
    |> StepRun.changeset(%{
      flow_run_id: run.id,
      step_id: "manifest",
      step_type: "manifest.build",
      status: "executing",
      attempt: 1,
      input: %{}
    })
    |> Repo.insert!()

    {:ok, view, _html} = live(conn, "/videos/#{video.id}")

    render_click(element(view, ~s([phx-value-tab="info"])))
    html = render(view)

    refute html =~ "Build Manifest"
    refute html =~ ~s(phx-click="toggle_flow_details")
    refute html =~ "retry-flow-step"
  end

  test "/videos/:id accepts legacy public id", %{conn: conn} do
    {conn, space} = authenticated_conn(conn)
    video = video_embed_fixture(space, %{name: "Public ID Video"})

    public_id = "#{space.hash}#{video.hash}"
    {:ok, _view, html} = live(conn, "/videos/#{public_id}")

    assert html =~ "Public ID Video"
  end

  test "/videos/:id redirects to /videos for invalid or out-of-space ids", %{conn: conn} do
    {conn, space} = authenticated_conn(conn)
    _local_video = video_embed_fixture(space, %{name: "Local Video"})

    other_space = space_fixture()
    other_video = video_embed_fixture(other_space, %{name: "Other Space Video"})

    assert {:error, {:live_redirect, %{to: "/videos"}}} =
             live(conn, "/videos/definitely-invalid-id")

    assert {:error, {:live_redirect, %{to: "/videos"}}} = live(conn, "/videos/#{other_video.id}")

    assert {:error, {:live_redirect, %{to: "/videos"}}} =
             live(conn, "/videos/#{other_space.hash <> other_video.hash}")
  end

  test "/videos/:id supports inline rename for videos and folders", %{conn: conn} do
    {conn, space} = authenticated_conn(conn)
    video = video_embed_fixture(space, %{name: "Rename Video"})
    folder = folder_embed_fixture(space, %{name: "Rename Folder"})

    {:ok, video_view, _html} = live(conn, "/videos/#{video.id}")

    assert render_change(element(video_view, "#video-title-form"), %{
             "rename" => %{"name" => "Renamed Video"}
           }) =~ "Renamed Video"

    stop_live_view(video_view)
    assert Repo.get!(Asset, video.asset_id).name == "Renamed Video"

    {:ok, folder_view, _html} = live(conn, "/videos/#{folder.id}")

    assert render_change(element(folder_view, "#folder-title-form"), %{
             "rename" => %{"name" => "Renamed Folder"}
           }) =~ "Renamed Folder"

    stop_live_view(folder_view)
    assert Repo.get!(Collection, folder.collection_id).name == "Renamed Folder"
  end

  test "/videos/:id publish persists settings and updates snippets", %{conn: conn} do
    {conn, space} = authenticated_conn(conn)
    video = video_embed_fixture(space, %{name: "Publish Video"})

    {:ok, view, _html} = live(conn, "/videos/#{video.id}")

    render_change(element(view, "#settings-style-form"), %{
      "settings" => %{"color" => "ff0000", "opacity" => "88"}
    })

    html = render(view)
    assert html =~ ~s(color="#ff0000")
    assert html =~ ~s(opacity="88")
    assert html =~ "display: block; width: 100%;"
    assert html =~ ~s(class="highlight")
    refute html =~ ~s(<div id="snippet-code" class="flex-grow text-stone-500 overflow-x-auto">\n)

    render_click(element(view, "#settings-publish"))
    stop_live_view(view)

    embed =
      Repo.get!(Embed, video.id)
      |> Repo.preload(:settings)

    assert embed.settings.color == "ff0000"
    assert embed.settings.opacity == 88

    {:ok, reloaded_view, reloaded_html} =
      live(conn, "/videos/#{video.id}")

    assert reloaded_html =~ ~s(color="#ff0000")
    assert reloaded_html =~ ~s(opacity="88")
    stop_live_view(reloaded_view)
  end

  test "/videos/:id renders an empty audio tracks state when there are no tracks", %{conn: conn} do
    {conn, space} = authenticated_conn(conn)
    video = video_embed_fixture(space, %{name: "Audio Track Settings"})

    {:ok, _view, html} = live(conn, "/videos/#{video.id}")

    assert html =~ "audio tracks"
    assert html =~ "add_audio_track"
  end

  test "/videos/:id renders audio track remove loading state", %{conn: conn} do
    {conn, space} = authenticated_conn(conn)

    video =
      video_embed_fixture(space, %{name: "Audio Track Remove Settings"})
      |> Repo.preload(asset: [:current_video])

    track =
      %AudioTrack{}
      |> AudioTrack.changeset(%{
        video_id: video.asset.current_video_id,
        label: "Commentary",
        language: "en",
        default: false,
        filename: "commentary.mp3",
        codec: "mp3"
      })
      |> Repo.insert!()

    {:ok, _view, html} = live(conn, "/videos/#{video.id}")

    assert html =~ "audio tracks"
    assert html =~ "Commentary"
    assert html =~ ~s(id="delete-audio-track-#{track.id}")
    assert html =~ "Remove audio track"
    assert html =~ "phx-click-loading:inline-flex"
  end

  test "/videos/:id saves audio track label on blur", %{conn: conn} do
    {conn, space} = authenticated_conn(conn)

    video =
      video_embed_fixture(space, %{name: "Audio Track Blur Settings"})
      |> Repo.preload(asset: [:current_video])

    track =
      %AudioTrack{}
      |> AudioTrack.changeset(%{
        video_id: video.asset.current_video_id,
        label: "Commentary",
        language: "en",
        default: false,
        filename: "commentary.mp3",
        codec: "mp3"
      })
      |> Repo.insert!()

    {:ok, view, html} = live(conn, "/videos/#{video.id}")

    assert html =~ ~s(phx-blur="blur_audio_track_label")
    refute html =~ ~s(phx-debounce="300")

    render_blur(element(view, ~s(input[name="audio_track[label]"])), %{
      "id" => track.id,
      "value" => "Director Commentary"
    })

    stop_live_view(view)
    assert Repo.get!(AudioTrack, track.id).label == "Director Commentary"
  end

  test "/videos/:id ignores audio track mutations from another space", %{conn: conn} do
    {conn, space} = authenticated_conn(conn)
    video = video_embed_fixture(space, %{name: "Audio Track Scoped Settings"})

    foreign_space = space_fixture()

    foreign_video =
      video_embed_fixture(foreign_space, %{name: "Foreign Audio Track Settings"})
      |> Repo.preload(asset: [:current_video])

    foreign_track =
      %AudioTrack{}
      |> AudioTrack.changeset(%{
        video_id: foreign_video.asset.current_video_id,
        label: "Foreign Commentary",
        language: "en",
        default: false,
        filename: "foreign-commentary.mp3",
        codec: "mp3"
      })
      |> Repo.insert!()

    {:ok, view, _html} = live(conn, "/videos/#{video.id}")
    component = with_target(view, "#video-settings")

    render_hook(component, "change_audio_track", %{
      "audio_track" => %{
        "id" => foreign_track.id,
        "label" => "Hijacked Commentary",
        "language" => "nl"
      }
    })

    render_hook(component, "blur_audio_track_label", %{
      "id" => foreign_track.id,
      "value" => "Hijacked Commentary"
    })

    render_hook(component, "change_audio_track_language", %{
      "id" => foreign_track.id,
      "value" => "nl"
    })

    render_hook(component, "delete_audio_track", %{"id" => foreign_track.id})

    stop_live_view(view)

    assert %AudioTrack{} = unchanged_track = Repo.get(AudioTrack, foreign_track.id)
    assert unchanged_track.video_id == foreign_track.video_id
    assert unchanged_track.label == "Foreign Commentary"
    assert unchanged_track.language == "en"
  end

  test "/videos/:id ignores subtitle mutations from another space", %{conn: conn} do
    {conn, space} = authenticated_conn(conn)
    video = video_embed_fixture(space, %{name: "Subtitle Scoped Settings"})

    foreign_space = space_fixture()

    foreign_video =
      video_embed_fixture(foreign_space, %{name: "Foreign Subtitle Settings"})
      |> Repo.preload(asset: [:current_video])

    foreign_subtitle =
      %Subtitle{}
      |> Subtitle.changeset(%{
        video_id: foreign_video.asset.current_video_id,
        language: "en",
        path: "#{foreign_video.hash}/subtitle_en.vtt"
      })
      |> Repo.insert!()

    {:ok, view, _html} = live(conn, "/videos/#{video.id}")
    component = with_target(view, "#video-settings")

    render_hook(component, "change_subtitle", %{
      "subtitle" => %{"id" => foreign_subtitle.id, "language" => "nl"}
    })

    render_hook(component, "delete_subtitle", %{"id" => foreign_subtitle.id})

    stop_live_view(view)

    assert %Subtitle{} = unchanged_subtitle = Repo.get(Subtitle, foreign_subtitle.id)
    assert unchanged_subtitle.video_id == foreign_subtitle.video_id
    assert unchanged_subtitle.language == "en"
    assert unchanged_subtitle.path == foreign_subtitle.path
  end

  test "/videos/:id shows audio track processing after upload completes", %{conn: conn} do
    {conn, space} = authenticated_conn(conn)
    video = video_embed_fixture(space, %{name: "Audio Track Processing Settings"})

    {:ok, view, _html} = live(conn, "/videos/#{video.id}")

    send(view.pid, {MaveCoreWeb.Dashboard.Videos.VideoSettingsComponent, :audio_track_uploaded})

    html = render(view)

    assert html =~ "audio tracks"
    assert html =~ "Audio track"
    assert html =~ "animate-spin rounded-full border border-stone-500 border-t-transparent"
  end

  test "/videos/:id refreshes the player when uploaded audio track processing completes", %{
    conn: conn
  } do
    {conn, space} = authenticated_conn(conn)

    video =
      video_embed_fixture(space, %{name: "Refresh Audio Track Player"})
      |> Repo.preload(asset: [:current_video])

    {:ok, view, initial_html} = live(conn, "/videos/#{video.id}")
    [_, player_dom_id] = Regex.run(~r/id="(player-[^"]+)"/, initial_html)

    send(view.pid, {MaveCoreWeb.Dashboard.Videos.VideoSettingsComponent, :audio_track_uploaded})

    %AudioTrack{}
    |> AudioTrack.changeset(%{
      video_id: video.asset.current_video_id,
      label: "Commentary",
      language: "en",
      default: false,
      filename: "commentary.mp3",
      codec: "mp3"
    })
    |> Repo.insert!()

    send(view.pid, {:reload_audio_tracks, video.id, 0, 10})

    html = render(view)
    [_, refreshed_player_dom_id] = Regex.run(~r/id="(player-[^"]+)"/, html)

    refute refreshed_player_dom_id == player_dom_id
    assert html =~ ~s(<mave-player embed="#{space.hash}#{video.hash}")
  end

  test "/videos/:id renders subtitle controls in settings", %{conn: conn} do
    {conn, space} = authenticated_conn(conn)

    video =
      video_embed_fixture(space, %{name: "Subtitle Settings"})
      |> Repo.preload(asset: [:current_video])

    subtitle =
      %Subtitle{}
      |> Subtitle.changeset(%{
        video_id: video.asset.current_video_id,
        language: "en",
        path: "#{video.hash}/subtitle_en.vtt"
      })
      |> Repo.insert!()

    {:ok, view, html} = live(conn, "/videos/#{video.id}")
    subtitle_download_path = "/#{space.id}/videos/#{video.id}/subtitles/#{subtitle.id}/download"

    assert html =~ "subtitles"
    assert html =~ "English"
    assert html =~ "add_subtitle"
    assert has_element?(view, ~s(a[href="#{subtitle_download_path}"][download="en.vtt"]))
    refute has_element?(view, ~s(a[href="#{subtitle_download_path}"][target]))
    assert html =~ ~s(id="delete-subtitle-#{subtitle.id}")
    assert html =~ "Remove subtitle"
    assert html =~ "phx-click-loading:inline-flex"
  end

  test "/videos/:id subtitle download returns VTT as an attachment", %{conn: conn} do
    {conn, space} = authenticated_conn(conn)

    video =
      video_embed_fixture(space, %{name: "Subtitle Download"})
      |> Repo.preload(asset: [:current_video])

    subtitle_key = "#{video.hash}/subtitle_en.vtt"
    subtitle_body = "WEBVTT\n\n00:00:00.000 --> 00:00:01.000\nHello\n"
    bucket = Storage.bucket_for_space(space.hash, space.region)

    assert {:ok, _body} =
             FlowStorageAdapterStub.put_public(
               bucket,
               subtitle_key,
               subtitle_body,
               "text/vtt",
               space.region
             )

    subtitle =
      %Subtitle{}
      |> Subtitle.changeset(%{
        video_id: video.asset.current_video_id,
        language: "en",
        path: subtitle_key
      })
      |> Repo.insert!()

    conn = get(conn, "/#{space.id}/videos/#{video.id}/subtitles/#{subtitle.id}/download")

    assert response(conn, 200) == subtitle_body
    assert [content_type] = get_resp_header(conn, "content-type")
    assert content_type =~ "text/vtt"
    assert [content_disposition] = get_resp_header(conn, "content-disposition")
    assert content_disposition =~ "attachment"
    assert content_disposition =~ ~s(filename="en.vtt")
  end

  test "/videos/:id shows subtitle processing after upload completes", %{conn: conn} do
    {conn, space} = authenticated_conn(conn)
    video = video_embed_fixture(space, %{name: "Subtitle Processing Settings"})

    {:ok, view, _html} = live(conn, "/videos/#{video.id}")

    send(view.pid, {MaveCoreWeb.Dashboard.Videos.VideoSettingsComponent, :subtitle_uploaded})

    html = render(view)

    assert html =~ "subtitles"
    assert html =~ "animate-spin rounded-full border border-stone-500 border-t-transparent"
  end

  test "/videos/:id refreshes the player when uploaded subtitle processing completes", %{
    conn: conn
  } do
    {conn, space} = authenticated_conn(conn)

    video =
      video_embed_fixture(space, %{name: "Refresh Uploaded Subtitle Player"})
      |> Repo.preload(asset: [:current_video])

    {:ok, view, initial_html} = live(conn, "/videos/#{video.id}")
    [_, player_dom_id] = Regex.run(~r/id="(player-[^"]+)"/, initial_html)

    send(view.pid, {MaveCoreWeb.Dashboard.Videos.VideoSettingsComponent, :subtitle_uploaded})

    %Subtitle{}
    |> Subtitle.changeset(%{
      video_id: video.asset.current_video_id,
      language: "en",
      path: "#{video.hash}/subtitle_en.vtt"
    })
    |> Repo.insert!()

    send(view.pid, {:reload_subtitles, video.id, 0, 10})

    html = render(view)
    [_, refreshed_player_dom_id] = Regex.run(~r/id="(player-[^"]+)"/, html)

    refute refreshed_player_dom_id == player_dom_id
    assert html =~ ~s(<mave-player embed="#{space.hash}#{video.hash}")
  end

  test "/videos/:id hides subtitle controls while the video is still processing", %{conn: conn} do
    {conn, space} = authenticated_conn(conn)

    video =
      video_embed_fixture(space, %{name: "Processing Subtitle Settings"})
      |> Repo.preload(asset: [:current_video])

    video.asset.current_video
    |> Video.changeset(%{status: "preparing"})
    |> Repo.update!()

    {:ok, _view, html} = live(conn, "/videos/#{video.id}")

    refute html =~ "subtitles"
    refute html =~ "add_subtitle"
  end

  test "/videos/:id renders an empty subtitles state when there are no subtitles yet", %{
    conn: conn
  } do
    {conn, space} = authenticated_conn(conn)
    video = video_embed_fixture(space, %{name: "Empty Subtitle Settings"})

    {:ok, _view, html} = live(conn, "/videos/#{video.id}")

    assert html =~ "subtitles"
    assert html =~ "add_subtitle"
  end

  test "/videos/:id renders thumbnail timecode preview with hls fallback", %{conn: conn} do
    {conn, space} = authenticated_conn(conn)

    video =
      video_embed_fixture(space, %{name: "Thumbnail Preview"})
      |> Repo.preload(asset: [:current_video])

    now = DateTime.utc_now() |> DateTime.truncate(:microsecond)

    Repo.insert_all("renditions", [
      %{
        id: MaveCore.LegacyShortUUID.dump!(Ecto.UUID.generate()),
        video_id: MaveCore.LegacyShortUUID.dump!(video.asset.current_video_id),
        rendition_key: "#{video.hash}/h264_sd_hls/playlist.m3u8",
        type: "video",
        codec: "h264",
        container: "hls",
        size: "sd",
        progress: 100.0,
        file_size: 1_000,
        inserted_at: now,
        updated_at: now
      }
    ])

    {:ok, video} =
      MaveCore.Embeds.update_settings(video, %{
        poster: :timecode,
        poster_time_second: 12.5
      })

    {:ok, _view, html} = live(conn, "/videos/#{video.id}")

    assert html =~ ~s(phx-hook="thumbnail_preview")
    assert html =~ ~s(data-preview-src="https://space-#{space.hash}.)
    assert html =~ ~s(data-fallback-src="https://space-#{space.hash}.)
    assert html =~ "#{video.hash}/h264_sd_hls/playlist.m3u8"
    assert html =~ "#{video.hash}/thumbnail_0.jpg"
  end

  test "/videos/:id normalizes thumbnail time inputs into hour minute second", %{conn: conn} do
    {conn, space} = authenticated_conn(conn)
    video = video_embed_fixture(space, %{name: "Normalize Thumbnail Time"})

    {:ok, video} =
      MaveCore.Embeds.update_settings(video, %{
        poster: :timecode,
        poster_time_second: 0
      })

    {:ok, view, _html} = live(conn, "/videos/#{video.id}")

    html =
      render_change(element(view, "#settings-poster-time-form"), %{
        "settings" => %{
          "poster_time_hour" => "0",
          "poster_time_minute" => "0",
          "poster_time_second" => "70"
        }
      })

    assert html =~ ~s(name="settings[poster_time_hour]" value="0")
    assert html =~ ~s(name="settings[poster_time_minute]" value="1")
    assert html =~ ~s(name="settings[poster_time_second]" value="10")

    stop_live_view(view)
  end

  test "/videos/:id keeps player stable during poster-only preview changes", %{conn: conn} do
    {conn, space} = authenticated_conn(conn)
    video = video_embed_fixture(space, %{name: "Stable Poster Preview"})

    {:ok, video} =
      MaveCore.Embeds.update_settings(video, %{
        poster: :timecode,
        poster_time_second: 0
      })

    {:ok, view, initial_html} = live(conn, "/videos/#{video.id}")

    [_, player_dom_id] = Regex.run(~r/id="(player-[^"]+)"/, initial_html)

    render_change(element(view, "#settings-poster-time-form"), %{
      "settings" => %{
        "poster_time_hour" => "0",
        "poster_time_minute" => "0",
        "poster_time_second" => "12"
      }
    })

    html = render(view)

    assert html =~ ~s(id="#{player_dom_id}")
    assert html =~ ~s(<mave-player embed="#{space.hash}#{video.hash}")
    assert html =~ ~s(poster="12")
  end

  test "/videos/:id refreshes the player when subtitle metadata changes", %{conn: conn} do
    {conn, space} = authenticated_conn(conn)
    video = video_embed_fixture(space, %{name: "Refresh Subtitle Player"})

    {:ok, view, initial_html} = live(conn, "/videos/#{video.id}")
    [_, player_dom_id] = Regex.run(~r/id="(player-[^"]+)"/, initial_html)

    send(view.pid, {MaveCoreWeb.Dashboard.Videos.VideoSettingsComponent, :subtitles_updated})

    html = render(view)
    [_, refreshed_player_dom_id] = Regex.run(~r/id="(player-[^"]+)"/, html)

    refute refreshed_player_dom_id == player_dom_id
    assert html =~ ~s(<mave-player embed="#{space.hash}#{video.hash}")
  end

  test "/videos/:id keeps the player stable after a completed flow step", %{conn: conn} do
    {conn, space} = authenticated_conn(conn)
    video = video_embed_fixture(space, %{name: "Refresh Completed Flow Player"})

    {:ok, view, initial_html} = live(conn, "/videos/#{video.id}")
    [_, player_dom_id] = Regex.run(~r/id="(player-[^"]+)"/, initial_html)

    send(
      view.pid,
      {:embed_updated,
       %{
         "space_id" => space.id,
         "embed_id" => video.id,
         "metadata_updated" => true
       }}
    )

    html = render(view)
    [_, refreshed_player_dom_id] = Regex.run(~r/id="(player-[^"]+)"/, html)

    assert refreshed_player_dom_id == player_dom_id
    assert html =~ ~s(<mave-player embed="#{space.hash}#{video.hash}")
  end

  test "/videos/:id renders real analytics data instead of mock metrics", %{
    conn: conn,
    db_name: db_name
  } do
    {conn, space} = authenticated_conn(conn)
    video = video_embed_fixture(space, %{name: "Analytics Video"})

    insert_video_view_events(db_name, space, video, 1_234)
    ClickHouseRepo.query("OPTIMIZE TABLE #{db_name}.events FINAL")

    {:ok, _view, html} = live(conn, "/videos/#{video.id}")

    assert html =~ ">1.234<"
    refute html =~ ">1.2K<"
  end

  test "/videos/:id samples dropoff chart from real retained view counts", %{
    conn: conn,
    db_name: db_name
  } do
    {conn, space} = authenticated_conn(conn)
    video = video_embed_fixture(space, %{name: "Single Viewer Dropoff"})
    session_id = "00000000-0000-0000-0000-000000000001"

    rows =
      [
        video_event_row(space, video, session_id, "play", 0.0, -40, 60),
        video_event_row(space, video, session_id, "pause", 30.0, -10, 60)
      ]
      |> Enum.join(",\n")

    sql = """
    INSERT INTO #{db_name}.events
    (timestamp, name, session_id, space_hash, embed_hash, video_time, duration, source_url, browser, browser_version, os, os_version, device, device_brand)
    VALUES
    #{rows}
    """

    {:ok, _} = ClickHouseRepo.query(sql)
    ClickHouseRepo.query("OPTIMIZE TABLE #{db_name}.events FINAL")

    {:ok, _view, html} = live(conn, "/videos/#{video.id}")

    [_, encoded_points] = Regex.run(~r/data-views="([^"]+)"/, html)
    assert {:ok, points} = Jason.decode(encoded_points)

    assert length(points) == 30
    assert hd(points) == 1
    assert 0 in points
    assert Enum.all?(points, &(&1 in [0, 1]))
  end

  @tag :audio_pipeline
  test "/videos/:id info tab identifies audio-only originals without video metadata", %{
    conn: conn
  } do
    {conn, space} = authenticated_conn(conn)

    embed =
      video_embed_fixture(space, %{name: "Audio Original"})
      |> Repo.preload(asset: [:current_video])

    {:ok, view, _html} = live(conn, "/videos/#{embed.id}")
    assert has_element?(view, "mave-player")
    assert has_element?(view, ~s([id^="player-"][class*="min-h-"]))

    embed.asset.current_video
    |> Video.changeset(%{max_width: nil, max_height: nil, max_frame_rate: nil, max_bitrate: nil})
    |> Repo.update!()

    %AudioTrack{}
    |> AudioTrack.changeset(%{
      video_id: embed.asset.current_video_id,
      filename: "audio_default.mp3",
      codec: "mp3",
      default: true
    })
    |> Repo.insert!()

    Events.broadcast_updated(space.id, embed.id)
    render(view)

    assert has_element?(view, ~s(mave-audio[embed="#{space.hash}#{embed.hash}"]))
    assert has_element?(view, ~s(mave-audio[style*="--mave-audio-min-height: 160px"]))
    assert has_element?(view, ~s|mave-audio[style*="min-height: var(--mave-audio-min-height)"]|)
    refute has_element?(view, ~s([id^="player-"][class*="min-h-"]))
    refute has_element?(view, ~s(mave-audio[style*="aspect-ratio"]))
    refute has_element?(view, ~s([phx-value-title="poster"][phx-value-label="timecode"]))
    refute has_element?(view, "#thumbnail-preview")
    refute has_element?(view, "#settings-poster-time-form")
    assert has_element?(view, ~s([phx-value-title="poster"][phx-value-label="upload"]))

    payload = MaveCore.Embeds.get_video_dashboard_payload(space, embed)
    assert is_nil(payload.thumbnail_preview)

    refute has_element?(view, ~s(mave-audio[controls*="thumbnail"]))
    materialize_custom_poster(embed, space)
    now = DateTime.utc_now() |> DateTime.truncate(:second)

    for size <- ["qhd", "uhd"] do
      Repo.insert_all("renditions", [
        %{
          id: MaveCore.LegacyShortUUID.dump!(Ecto.UUID.generate()),
          video_id: MaveCore.LegacyShortUUID.dump!(embed.asset.current_video_id),
          rendition_key: "#{embed.hash}/h264_#{size}_hls/playlist.m3u8",
          type: "video",
          codec: "h264",
          container: "hls",
          size: size,
          progress: 0.0,
          inserted_at: now,
          updated_at: now
        }
      ])
    end

    Events.broadcast_updated(space.id, embed.id)
    render(view)

    assert has_element?(view, ~s(mave-audio[controls="full thumbnail"]))
    assert has_element?(view, ~s(mave-audio[poster*="thumbnail.jpg?e="]))

    refute has_element?(view, "mave-player")
    assert has_element?(view, ".mave-snippet-tag", "mave-audio")
    refute has_element?(view, ~s([phx-value-preview="clip"]))

    for framework <- ~w(react vue) do
      render_click(element(view, ~s([phx-value-preview="#{framework}"])))
      assert has_element?(view, ".mave-snippet-tag", "Audio")
    end

    render_click(element(view, ~s([phx-value-tab="info"])))

    assert has_element?(view, "#original-media-kind", "Audio only")
    refute has_element?(view, "#rendition-group-videos")
    refute has_element?(view, "#rendition-group-clips")
    refute has_element?(view, "#rendition-group-keyframes")
    refute has_element?(view, ".rendition-status-indicator")
    assert has_element?(view, "#rendition-group-audio")
    assert has_element?(view, "#rendition-group-images")
    assert has_element?(view, "#original-file-size", "MB")
    refute has_element?(view, "#original-resolution")
    refute has_element?(view, "#original-frame-rate")
    refute has_element?(view, "#original-bitrate")
  end

  @tag :audio_pipeline
  test "/videos/:id info tab keeps valid video metadata", %{conn: conn} do
    {conn, space} = authenticated_conn(conn)
    embed = video_embed_fixture(space, %{name: "Video Original"})

    {:ok, view, _html} = live(conn, "/videos/#{embed.id}")
    render_click(element(view, ~s([phx-value-tab="info"])))

    assert has_element?(view, "#original-resolution", "1920")
    assert has_element?(view, "#original-resolution", "1080")
    assert has_element?(view, "#original-frame-rate", "30")
    assert has_element?(view, "#original-bitrate", "10.0")
    assert has_element?(view, "#original-file-size", "MB")
    refute has_element?(view, "#original-media-kind")
  end

  test "/videos/:id info tab hides unknown dimensions without assuming audio", %{conn: conn} do
    {conn, space} = authenticated_conn(conn)

    embed =
      video_embed_fixture(space, %{name: "Unknown Original"})
      |> Repo.preload(asset: [:current_video])

    embed.asset.current_video
    |> Video.changeset(%{max_width: 0, max_height: 0, max_frame_rate: 0.0, max_bitrate: 0})
    |> Repo.update!()

    {:ok, view, _html} = live(conn, "/videos/#{embed.id}")
    render_click(element(view, ~s([phx-value-tab="info"])))

    assert has_element?(view, "#original-file-size", "MB")
    refute has_element?(view, "#original-media-kind")
    refute has_element?(view, "#original-resolution")
    refute has_element?(view, "#original-frame-rate")
    refute has_element?(view, "#original-bitrate")
  end

  test "/videos/:id info tab renders unfinished audio as one normalized track", %{conn: conn} do
    {conn, space} = authenticated_conn(conn)

    video =
      video_embed_fixture(space, %{name: "Audio Rendition In Progress"})
      |> Repo.preload(asset: [:current_video])

    now = DateTime.utc_now() |> DateTime.truncate(:microsecond)

    Repo.insert_all("renditions", [
      %{
        id: MaveCore.LegacyShortUUID.dump!(Ecto.UUID.generate()),
        video_id: MaveCore.LegacyShortUUID.dump!(video.asset.current_video_id),
        rendition_key: "audio_default.mp3",
        type: "audio",
        codec: "mp3",
        container: "mp3",
        size: nil,
        progress: 100.0,
        file_size: 500,
        inserted_at: now,
        updated_at: now
      },
      %{
        id: MaveCore.LegacyShortUUID.dump!(Ecto.UUID.generate()),
        video_id: MaveCore.LegacyShortUUID.dump!(video.asset.current_video_id),
        rendition_key: "audio_default_hls/playlist.m3u8",
        type: "audio",
        codec: "aac",
        container: "hls",
        size: nil,
        progress: 100.0,
        file_size: 600,
        inserted_at: now,
        updated_at: now
      }
    ])

    {:ok, view, _html} = live(conn, "/videos/#{video.id}")

    render_click(element(view, ~s([phx-value-tab="info"])))
    html = render(view)

    assert html =~ "Original"
    assert length(Regex.scan(~r/MP3/, html)) == 1
    assert length(Regex.scan(~r/HLS/, html)) == 1
    refute html =~ "MP3 (MP3)"
  end

  test "/videos/:id info tab groups renditions by type like old mave", %{conn: conn} do
    {conn, space} = authenticated_conn(conn)

    video =
      video_embed_fixture(space, %{name: "Grouped Renditions Video"})
      |> Repo.preload(asset: [:current_video])

    now = DateTime.utc_now() |> DateTime.truncate(:microsecond)

    Repo.insert_all("renditions", [
      %{
        id: MaveCore.LegacyShortUUID.dump!(Ecto.UUID.generate()),
        video_id: MaveCore.LegacyShortUUID.dump!(video.asset.current_video_id),
        rendition_key: "video_h264_sd.mp4",
        type: "video",
        codec: "h264",
        container: "mp4",
        size: "sd",
        progress: 100.0,
        file_size: 1_000,
        inserted_at: now,
        updated_at: now
      },
      %{
        id: MaveCore.LegacyShortUUID.dump!(Ecto.UUID.generate()),
        video_id: MaveCore.LegacyShortUUID.dump!(video.asset.current_video_id),
        rendition_key: "audio_default.mp3",
        type: "audio",
        codec: "mp3",
        container: "mp3",
        size: nil,
        progress: 100.0,
        file_size: 500,
        inserted_at: now,
        updated_at: now
      },
      %{
        id: MaveCore.LegacyShortUUID.dump!(Ecto.UUID.generate()),
        video_id: MaveCore.LegacyShortUUID.dump!(video.asset.current_video_id),
        rendition_key: "audio_default_hls/playlist.m3u8",
        type: "audio",
        codec: "aac",
        container: "hls",
        size: nil,
        progress: 100.0,
        file_size: 600,
        inserted_at: now,
        updated_at: now
      },
      %{
        id: MaveCore.LegacyShortUUID.dump!(Ecto.UUID.generate()),
        video_id: MaveCore.LegacyShortUUID.dump!(video.asset.current_video_id),
        rendition_key: "poster.jpg",
        type: "poster",
        codec: "jpg",
        container: "jpg",
        size: nil,
        progress: 100.0,
        file_size: 250,
        inserted_at: now,
        updated_at: now
      },
      %{
        id: MaveCore.LegacyShortUUID.dump!(Ecto.UUID.generate()),
        video_id: MaveCore.LegacyShortUUID.dump!(video.asset.current_video_id),
        rendition_key: "keyframes.mp4",
        type: "clip_keyframes",
        codec: "h264",
        container: "mp4",
        size: "sd",
        progress: 100.0,
        file_size: 750,
        inserted_at: now,
        updated_at: now
      },
      %{
        id: MaveCore.LegacyShortUUID.dump!(Ecto.UUID.generate()),
        video_id: MaveCore.LegacyShortUUID.dump!(video.asset.current_video_id),
        rendition_key: "clip.mp4",
        type: "clip",
        codec: "hevc",
        container: "mp4",
        size: "sd",
        progress: 100.0,
        file_size: 900,
        inserted_at: now,
        updated_at: now
      }
    ])

    Repo.insert_all("audio_tracks", [
      %{
        id: MaveCore.LegacyShortUUID.dump!(Ecto.UUID.generate()),
        video_id: MaveCore.LegacyShortUUID.dump!(video.asset.current_video_id),
        label: "Commentary",
        language: "nl",
        default: false,
        codec: "mp3",
        file_size: 500,
        filename: "audio_default.mp3",
        inserted_at: now,
        updated_at: now
      }
    ])

    %Subtitle{}
    |> Subtitle.changeset(%{
      video_id: video.asset.current_video_id,
      language: "nl",
      path: "#{video.hash}/subtitle_nl.vtt"
    })
    |> Repo.insert!()

    {:ok, view, _html} = live(conn, "/videos/#{video.id}")

    render_click(element(view, ~s([phx-value-tab="info"])))
    html = render(view)

    assert html =~ ">videos<"
    assert html =~ ">audio<"
    assert html =~ ">subtitles<"
    assert html =~ ">clips<"
    assert html =~ ">images<"
    assert html =~ ">keyframes<"
    assert html =~ "480p"
    assert html =~ "MP3"
    assert html =~ "HLS"
    assert html =~ "H.265"
    assert html =~ "Commentary"
    assert html =~ "Dutch"
    assert html =~ "VTT"
    assert html =~ "Poster"
  end

  test "/videos/:id info tab hides non-concrete hls master rows", %{conn: conn} do
    {conn, space} = authenticated_conn(conn)

    video =
      video_embed_fixture(space, %{name: "Hide HLS Master"})
      |> Repo.preload(asset: [:current_video])

    now = DateTime.utc_now() |> DateTime.truncate(:microsecond)

    Repo.insert_all("renditions", [
      %{
        id: MaveCore.LegacyShortUUID.dump!(Ecto.UUID.generate()),
        video_id: MaveCore.LegacyShortUUID.dump!(video.asset.current_video_id),
        rendition_key: "video_h264_sd.mp4",
        type: "video",
        codec: "h264",
        container: "mp4",
        size: "sd",
        progress: 100.0,
        file_size: 1_000,
        inserted_at: now,
        updated_at: now
      },
      %{
        id: MaveCore.LegacyShortUUID.dump!(Ecto.UUID.generate()),
        video_id: MaveCore.LegacyShortUUID.dump!(video.asset.current_video_id),
        rendition_key: "playlist.m3u8",
        type: "video",
        codec: "h264",
        container: "hls",
        size: nil,
        progress: 100.0,
        file_size: 250,
        inserted_at: now,
        updated_at: now
      },
      %{
        id: MaveCore.LegacyShortUUID.dump!(Ecto.UUID.generate()),
        video_id: MaveCore.LegacyShortUUID.dump!(video.asset.current_video_id),
        rendition_key: "poster.jpg",
        type: "poster",
        codec: nil,
        container: "jpg",
        size: nil,
        progress: 100.0,
        file_size: 25,
        inserted_at: now,
        updated_at: now
      }
    ])

    {:ok, view, _html} = live(conn, "/videos/#{video.id}")

    render_click(element(view, ~s([phx-value-tab="info"])))
    html = render(view)

    assert html =~ "480p"
    assert Regex.scan(~r/>HLS</, html) == []
    refute html =~ ">Auto<"
  end

  test "/videos/:id info tab orders rendition format badges consistently", %{conn: conn} do
    {conn, space} = authenticated_conn(conn)

    video =
      video_embed_fixture(space, %{name: "Consistent Rendition Order"})
      |> Repo.preload(asset: [:current_video])

    now = DateTime.utc_now() |> DateTime.truncate(:microsecond)

    Repo.insert_all("renditions", [
      %{
        id: MaveCore.LegacyShortUUID.dump!(Ecto.UUID.generate()),
        video_id: MaveCore.LegacyShortUUID.dump!(video.asset.current_video_id),
        rendition_key: "poster.webp",
        type: "poster",
        codec: nil,
        container: "webp",
        size: nil,
        progress: 100.0,
        file_size: 25,
        inserted_at: now,
        updated_at: now
      },
      %{
        id: MaveCore.LegacyShortUUID.dump!(Ecto.UUID.generate()),
        video_id: MaveCore.LegacyShortUUID.dump!(video.asset.current_video_id),
        rendition_key: "poster.avif",
        type: "poster",
        codec: nil,
        container: "avif",
        size: nil,
        progress: 100.0,
        file_size: 25,
        inserted_at: now,
        updated_at: now
      },
      %{
        id: MaveCore.LegacyShortUUID.dump!(Ecto.UUID.generate()),
        video_id: MaveCore.LegacyShortUUID.dump!(video.asset.current_video_id),
        rendition_key: "poster.jpg",
        type: "poster",
        codec: nil,
        container: "jpg",
        size: nil,
        progress: 100.0,
        file_size: 25,
        inserted_at: now,
        updated_at: now
      }
    ])

    {:ok, view, _html} = live(conn, "/videos/#{video.id}")

    render_click(element(view, ~s([phx-value-tab="info"])))
    html = render(view)

    assert html =~ "JPG"
    assert html =~ "WebP"
    assert html =~ "AVIF"

    jpg_pos = html |> :binary.match("JPG") |> elem(0)
    webp_pos = html |> :binary.match("WebP") |> elem(0)
    avif_pos = html |> :binary.match("AVIF") |> elem(0)

    assert jpg_pos < webp_pos
    assert webp_pos < avif_pos
  end

  test "/videos/:id archive and delete actions mutate embeds and redirect to the tab root", %{
    conn: conn
  } do
    {conn, space} = authenticated_conn(conn)
    video = video_embed_fixture(space, %{name: "Archive Me"})
    folder = folder_embed_fixture(space, %{name: "Delete Me", archived: true})

    {:ok, archive_view, _html} = live(conn, "/videos/#{video.id}")

    archive_html =
      render_click(element(archive_view, "#video-actions .cursor-pointer", "archive"))

    assert archive_html =~
             "Move this video to the archive? You can restore it from the archive later."

    refute archive_html =~ "This action cannot be reversed."

    assert {:error, {:live_redirect, %{to: "/videos"}}} =
             render_click(element(archive_view, "#dialog button", "confirm"))

    assert Repo.get!(Embed, video.id).archived

    {:ok, delete_view, _html} =
      live(conn, "/videos/#{folder.id}?tab=archive")

    delete_html = render_click(element(delete_view, "#folder-delete-button"))

    assert delete_html =~ "This action cannot be reversed."

    assert {:error, {:live_redirect, %{to: "/videos?tab=archive"}}} =
             render_click(element(delete_view, "#dialog button", "confirm"))

    refute Repo.get(Embed, folder.id)
  end

  test "/videos/:id delete failures show an error", %{conn: conn} do
    old_storage_module = Application.get_env(:mave_core, :storage_module)
    Application.put_env(:mave_core, :storage_module, FailingStorage)

    on_exit(fn -> restore_env(:storage_module, old_storage_module) end)

    {conn, space} = authenticated_conn(conn)
    video = video_embed_fixture(space, %{name: "Delete Fails"})

    {:ok, view, _html} = live(conn, "/videos/#{video.id}")

    render_click(element(view, "#video-actions .cursor-pointer", "delete"))
    html = render_click(element(view, "#dialog button", "confirm"))

    assert html =~ "Could not delete this item"
    refute Repo.get!(Embed, video.id).deleted_at
  end

  test "/videos/:id folder mode can create children inside the current folder", %{conn: conn} do
    {conn, space} = authenticated_conn(conn)
    folder = folder_embed_fixture(space, %{name: "Parent Folder"})

    {:ok, view, _html} = live(conn, "/videos/#{folder.id}")

    {:error, {:live_redirect, %{to: to}}} =
      view
      |> element("#folder-create-video")
      |> render_click()

    created_id =
      to
      |> String.trim_leading("/videos/")
      |> String.split("?")
      |> List.first()

    assert {:ok, embed} = MaveCore.Embeds.resolve_dashboard_embed(space, created_id)

    assert Repo.aggregate(
             from(ce in CollectionEmbed,
               where: ce.collection_id == ^folder.collection_id and ce.embed_id == ^embed.id
             ),
             :count,
             :id
           ) == 1
  end

  test "/videos/:id folder mode updates when another session creates a child video", %{conn: conn} do
    {conn, space} = authenticated_conn(conn)
    folder = folder_embed_fixture(space, %{name: "Realtime Folder"})

    {:ok, view, html} = live(conn, "/videos/#{folder.id}")

    refute html =~ "Realtime Child"

    assert {:ok, _embed} =
             MaveCore.Embeds.create_video_embed(space, %{
               name: "Realtime Child",
               parent_folder_id: folder.id
             })

    assert_eventually(fn -> render(view) =~ "Realtime Child" end)
  end

  test "/videos/:id folder mode can drag child items into folders and back to root", %{conn: conn} do
    {conn, space} = authenticated_conn(conn)
    source_folder = folder_embed_fixture(space, %{name: "Source Folder"})
    target_folder = folder_embed_fixture(space, %{name: "Target Folder"})
    video = video_embed_fixture(space, %{name: "Child Video"})

    link_embed_to_folder(source_folder, video)

    {:ok, view, _html} = live(conn, "/videos/#{source_folder.id}")

    moved_html = render_hook(view, "drop_embed", %{"id" => video.id, "to" => target_folder.id})

    assert moved_html =~ "Item moved"
    refute render(view) =~ "Child Video"

    target_items = MaveCore.Embeds.list_folder_items(space, target_folder)
    assert Enum.any?(target_items.videos, &(&1.uuid == video.id))

    link_embed_to_folder(source_folder, video)
    {:ok, view, _html} = live(conn, "/videos/#{source_folder.id}")

    remove_html = render_hook(view, "drop_embed", %{"id" => video.id, "to" => ""})

    assert remove_html =~ "Item moved"
    refute render(view) =~ "Child Video"
  end

  defp authenticated_conn(conn) do
    email = "videos-show-#{System.unique_integer([:positive])}@example.com"
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

  defp space_fixture do
    email = "videos-space-#{System.unique_integer([:positive])}@example.com"
    {:ok, user} = Accounts.create_user(email)
    user.current_space_membership.space
  end

  defp with_manage_host(conn) do
    case System.get_env("MAVE_MANAGE_HOST") do
      host when is_binary(host) and host != "" -> %{conn | host: host}
      _ -> conn
    end
  end

  defp insert_video_view_events(db_name, %Space{} = space, %Embed{} = video, count) do
    rows =
      1..count
      |> Enum.flat_map(fn index ->
        session_id =
          "00000000-0000-0000-0000-" <>
            (index |> Integer.to_string() |> String.pad_leading(12, "0"))

        [
          video_event_row(space, video, session_id, "play", 0.0, -10),
          video_event_row(space, video, session_id, "pause", 2.0, -8)
        ]
      end)
      |> Enum.join(",\n")

    sql = """
    INSERT INTO #{db_name}.events
    (timestamp, name, session_id, space_hash, embed_hash, video_time, duration, source_url, browser, browser_version, os, os_version, device, device_brand)
    VALUES
    #{rows}
    """

    {:ok, _} = ClickHouseRepo.query(sql)
  end

  defp video_event_row(
         %Space{} = space,
         %Embed{} = video,
         session_id,
         name,
         video_time,
         seconds_ago,
         duration \\ 10
       ) do
    [
      "(addSeconds(now64(6), #{seconds_ago}), ",
      "'#{name}', '#{session_id}', '#{space.hash}', '#{video.hash}', ",
      "#{video_time}, #{duration}, ",
      "'https://example.com/watch/abc', ",
      "'Chrome', '100', 'Mac', '14', 'Desktop', 'Apple')"
    ]
    |> IO.iodata_to_binary()
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
        status: "ready",
        file_name: "#{Map.get(attrs, :name, "video")}.mp4",
        max_width: 1920,
        max_height: 1080,
        max_frame_rate: 30.0,
        max_bitrate: 10_000_000,
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
      archived: Map.get(attrs, :archived, false)
    })
    |> Repo.insert!()
  end

  defp placeholder_video_embed_fixture(%Space{} = space, attrs) do
    asset =
      %Asset{}
      |> Asset.changeset(%{
        space_id: space.id,
        name: Map.get(attrs, :name, "Upload Placeholder")
      })
      |> Repo.insert!()

    %Embed{}
    |> Embed.changeset(%{
      space_id: space.id,
      asset_id: asset.id,
      hash: unique_embed_hash(),
      type: :video,
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

  defp unique_embed_hash do
    System.unique_integer([:positive])
    |> Integer.to_string(36)
    |> String.pad_leading(10, "0")
    |> String.slice(-10, 10)
  end

  defp assert_eventually(fun, attempts \\ 20)

  defp assert_eventually(fun, attempts) when attempts > 0 do
    if fun.() do
      :ok
    else
      Process.sleep(25)
      assert_eventually(fun, attempts - 1)
    end
  end

  defp assert_eventually(_fun, 0), do: flunk("condition did not become true in time")

  defp highlighted_text(html) do
    html
    |> String.replace(~r/<[^>]+>/, "")
    |> String.replace(~r/\s+/, "")
    |> String.replace("&quot;", "\"")
    |> String.replace("&lt;", "<")
    |> String.replace("&gt;", ">")
    |> String.replace("&amp;", "&")
  end

  defp with_default_component_runtime(fun) do
    original_playback_origin = Application.get_env(:mave_core, :playback_origin)
    original_domain = Application.get_env(:mave_core, :domain)
    original_upload = Application.get_env(:mave_core, :upload)
    original_cdn_host = Application.get_env(:mave_core, :public_cdn_host)
    original_cdn_scheme = Application.get_env(:mave_core, :public_cdn_scheme)
    original_cdn_mode = Application.get_env(:mave_core, :public_cdn_mode)
    original_components_src = Application.get_env(:mave_core, :components_src)
    original_components_base_url = Application.get_env(:mave_core, :components_base_url)
    original_api_host = System.get_env("MAVE_API_HOST")
    original_metrics_host = System.get_env("MAVE_METRICS_HOST")

    try do
      Application.put_env(:mave_core, :playback_origin, "https://signed.video-dns.com")
      Application.put_env(:mave_core, :domain, "https://dash.mave.io")

      Application.put_env(:mave_core, :upload,
        endpoint: "https://upload.mave.io/files",
        source_base_url: "https://s3.fr-par.scw.cloud",
        public_base_url: "https://storage.mave.io",
        source_region: "fr-par",
        hook_secret: "secret",
        default_template: "publish_default"
      )

      Application.put_env(:mave_core, :public_cdn_host, "video-dns.com")
      Application.put_env(:mave_core, :public_cdn_scheme, "https")
      Application.delete_env(:mave_core, :public_cdn_mode)
      Application.delete_env(:mave_core, :components_src)
      Application.delete_env(:mave_core, :components_base_url)
      System.put_env("MAVE_API_HOST", "api.mave.io")
      System.put_env("MAVE_METRICS_HOST", "metrics.video-dns.com")

      fun.()
    after
      restore_env(:playback_origin, original_playback_origin)
      restore_env(:domain, original_domain)
      restore_env(:upload, original_upload)
      restore_env(:public_cdn_host, original_cdn_host)
      restore_env(:public_cdn_scheme, original_cdn_scheme)
      restore_env(:public_cdn_mode, original_cdn_mode)
      restore_env(:components_src, original_components_src)
      restore_env(:components_base_url, original_components_base_url)
      restore_system_env("MAVE_API_HOST", original_api_host)
      restore_system_env("MAVE_METRICS_HOST", original_metrics_host)
    end
  end

  defp restore_env(key, nil), do: Application.delete_env(:mave_core, key)
  defp restore_env(key, value), do: Application.put_env(:mave_core, key, value)

  defp restore_system_env(key, nil), do: System.delete_env(key)
  defp restore_system_env(key, value), do: System.put_env(key, value)
end
