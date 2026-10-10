defmodule MaveCore.EmbedsTest do
  use MaveCore.DataCase, async: false

  alias MaveCore.Accounts
  alias MaveCore.Assets.{Asset, AudioTrack, Subtitle, Video}
  alias MaveCore.Collections.{Collection, CollectionEmbed}
  alias MaveCore.Embeds
  alias MaveCore.Embeds.{Embed, Events, SettingsSerializer}
  alias MaveCore.Flow
  alias MaveCore.Flow.{Run, StepRun}
  alias MaveCore.Spaces.Space
  alias MaveCore.TestSupport.FlowStorageAdapterStub

  defmodule TimecodeThumbnailImageProcessor do
    def process(_space_hash, _embed_hash, seconds, opts) do
      format = Keyword.fetch!(opts, :format)
      {:ok, "cache/#{format}", "thumbnail #{format} at #{seconds}"}
    end
  end

  test "resolve_dashboard_embed accepts uuid, shortuuid, public id and hash" do
    space = space_fixture()
    video = video_embed_fixture(space, %{name: "Resolver Video"})

    assert {:ok, resolved_uuid} = Embeds.resolve_dashboard_embed(space, video.id)
    assert resolved_uuid.id == video.id

    short_id = video.id
    assert {:ok, resolved_short} = Embeds.resolve_dashboard_embed(space, short_id)
    assert resolved_short.id == video.id

    public_id = "#{space.hash}#{video.hash}"
    assert {:ok, resolved_public} = Embeds.resolve_dashboard_embed(space, public_id)
    assert resolved_public.id == video.id

    assert {:ok, resolved_hash} = Embeds.resolve_dashboard_embed(space, video.hash)
    assert resolved_hash.id == video.id
  end

  test "resolve_dashboard_embed rejects invalid and cross-space ids" do
    space = space_fixture()
    other_space = space_fixture()
    other_video = video_embed_fixture(other_space, %{name: "Other Space Video"})

    assert {:error, :not_found} = Embeds.resolve_dashboard_embed(space, "not-a-valid-id")
    assert {:error, :not_found} = Embeds.resolve_dashboard_embed(space, other_video.id)
    assert {:error, :not_found} = Embeds.resolve_dashboard_embed(space, other_video.hash)

    assert {:error, :not_found} =
             Embeds.resolve_dashboard_embed(space, "#{other_space.hash}#{other_video.hash}")
  end

  test "list_root_items excludes embeds already present in collection_embeds" do
    space = space_fixture()
    _root_video = video_embed_fixture(space, %{name: "Root Video"})
    root_folder = folder_embed_fixture(space, %{name: "Root Folder"})
    nested_video = video_embed_fixture(space, %{name: "Nested Video"})

    link_embed_to_folder(root_folder, nested_video)

    %{folders: folders, videos: videos} = Embeds.list_root_items(space, :all)

    assert Enum.any?(folders, &(&1.name == "Root Folder"))
    assert Enum.any?(videos, &(&1.name == "Root Video"))
    refute Enum.any?(videos, &(&1.name == "Nested Video"))
  end

  test "list_root_items filters archive tab by archived flag" do
    space = space_fixture()
    _active_video = video_embed_fixture(space, %{name: "Active Root Video", archived: false})
    _archived_video = video_embed_fixture(space, %{name: "Archived Root Video", archived: true})

    %{videos: archived_videos} = Embeds.list_root_items(space, :archive)
    %{videos: active_videos} = Embeds.list_root_items(space, :all)

    assert Enum.any?(archived_videos, &(&1.name == "Archived Root Video"))
    refute Enum.any?(archived_videos, &(&1.name == "Active Root Video"))

    assert Enum.any?(active_videos, &(&1.name == "Active Root Video"))
    refute Enum.any?(active_videos, &(&1.name == "Archived Root Video"))
  end

  test "list_folder_items returns mixed items and folder_video_counts include nested videos" do
    space = space_fixture()
    folder_a = folder_embed_fixture(space, %{name: "Folder A"})
    folder_b = folder_embed_fixture(space, %{name: "Folder B"})
    video_a = video_embed_fixture(space, %{name: "Video in A", archived: false})
    video_b = video_embed_fixture(space, %{name: "Archived Video in B", archived: true})

    link_embed_to_folder(folder_a, folder_b)
    link_embed_to_folder(folder_a, video_a)
    link_embed_to_folder(folder_b, video_b)

    %{folders: folders, videos: videos} = Embeds.list_folder_items(space, folder_a)
    counts = Embeds.folder_video_counts(space, [folder_a.id, folder_b.id])

    assert Enum.any?(folders, &(&1.name == "Folder B"))
    assert Enum.any?(videos, &(&1.name == "Video in A"))

    assert counts[folder_a.id] == 2
    assert counts[folder_b.id] == 1
  end

  test "list_folder_items paginates folder contents" do
    space = space_fixture()
    folder = folder_embed_fixture(space, %{name: "Paged Folder"})

    embeds =
      for index <- 1..16 do
        video = video_embed_fixture(space, %{name: "Paged Child #{index}"})
        link_embed_to_folder(folder, video)
        video
      end

    oldest = hd(embeds)
    newest = List.last(embeds)

    first_page = Embeds.list_folder_items(space, folder, page: 1)
    second_page = Embeds.list_folder_items(space, folder, page: 2)

    assert first_page.page == 1
    assert first_page.total_items == 16
    assert first_page.total_pages == 2
    assert length(first_page.videos) == 15
    assert Enum.any?(first_page.videos, &(&1.uuid == newest.id))
    refute Enum.any?(first_page.videos, &(&1.uuid == oldest.id))

    assert second_page.page == 2
    assert second_page.total_items == 16
    assert second_page.total_pages == 2
    assert Enum.map(second_page.videos, & &1.uuid) == [oldest.id]
  end

  test "update_settings creates settings and get_video_dashboard_payload exposes legacy player attrs" do
    space = space_fixture()
    video = video_embed_fixture(space, %{name: "Settings Video"})

    assert {:ok, video} =
             Embeds.update_settings(video, %{
               controls_enabled: false,
               aspect_ratio_enabled: false,
               width: "720px",
               height: "405px",
               autoplay_enabled: true,
               autoplay: :always,
               loop_enabled: true,
               poster: :timecode,
               poster_time_hour: 0,
               poster_time_minute: 0,
               poster_time_second: 12.5
             })

    assert video.settings.controls_enabled == false
    assert video.settings.poster_time_seconds == 12.5

    payload = Embeds.get_video_dashboard_payload(space, video)

    assert payload.public_id == "#{space.hash}#{video.hash}"
    assert {"controls", "none"} in payload.player_attributes
    assert {"width", "720px"} in payload.player_attributes
    assert {"height", "405px"} in payload.player_attributes
    assert {"autoplay", "always"} in payload.player_attributes
    assert {"loop", "loop"} in payload.player_attributes
    assert {"poster", "12.5"} in payload.player_attributes
    assert payload.iframe_dimensions == %{width: "720", height: "405"}
  end

  test "dashboard identifies audio from inspection only for the current video version" do
    space = space_fixture()
    embed = video_embed_fixture(space, %{name: "Inspected Audio"})

    embed.asset.current_video
    |> Video.changeset(%{max_width: nil, max_height: nil, max_frame_rate: nil, max_bitrate: nil})
    |> Repo.update!()

    {:ok, template} =
      Flow.create_template(%{
        "slug" => "audio-info-#{System.unique_integer([:positive])}",
        "name" => "Audio Info"
      })

    {:ok, version} =
      Flow.create_version(template.id, %{
        "definition" => %{
          "steps" => [%{"id" => "inspect_media", "type" => "media.inspect", "name" => "Inspect"}]
        }
      })

    input = %{
      "space_hash" => space.hash,
      "embed_hash" => embed.hash,
      "version" => Embeds.current_video_version(embed)
    }

    run =
      %Run{}
      |> Run.changeset(%{
        flow_template_id: template.id,
        flow_version_id: version.id,
        status: "running",
        input: input
      })
      |> Repo.insert!()

    %StepRun{}
    |> StepRun.changeset(%{
      flow_run_id: run.id,
      step_id: "inspect_media",
      step_type: "media.inspect",
      status: "succeeded",
      output: %{"has_audio" => true, "has_video" => false}
    })
    |> Repo.insert!()

    payload = Embeds.get_video_dashboard_payload(space, embed)
    assert payload.original.audio_only
    assert payload.resolution == "Audio"

    run
    |> Run.changeset(%{input: Map.put(input, "version", input["version"] - 1)})
    |> Repo.update!()

    refute Embeds.get_video_dashboard_payload(space, embed).original.audio_only
  end

  test "processing payload refresh preserves already-loaded analytics" do
    space = space_fixture()
    video = video_embed_fixture(space, %{name: "Processing Analytics"})

    previous_payload =
      space
      |> Embeds.get_video_dashboard_payload(video)
      |> Map.merge(%{
        views_today: 11,
        views_month: 22,
        views_year: 33,
        sources: [%{source: "dashboard", count: 7}],
        engagement: [%{second: 0, views: 4}]
      })

    refreshed =
      Embeds.refresh_video_dashboard_processing_payload(space, video, previous_payload)

    assert refreshed.views_today == 11
    assert refreshed.views_month == 22
    assert refreshed.views_year == 33
    assert refreshed.sources == [%{source: "dashboard", count: 7}]
    assert refreshed.engagement == [%{second: 0, views: 4}]
  end

  test "delete_external_poster restores generated thumbnail and clears custom thumbnail state" do
    old_storage_adapter = Application.get_env(:mave_core, :flow_storage_adapter)
    Application.put_env(:mave_core, :flow_storage_adapter, FlowStorageAdapterStub)
    FlowStorageAdapterStub.reset!()

    on_exit(fn ->
      FlowStorageAdapterStub.reset!()

      if old_storage_adapter do
        Application.put_env(:mave_core, :flow_storage_adapter, old_storage_adapter)
      else
        Application.delete_env(:mave_core, :flow_storage_adapter)
      end
    end)

    space = space_fixture()

    embed =
      video_embed_fixture(space, %{name: "Delete Custom Thumbnail"})
      |> Repo.preload([:space, :settings, asset: [:current_video]])

    {:ok, embed} =
      Embeds.update_settings(embed, %{
        poster: :upload,
        external_poster:
          SettingsSerializer.storage_object_url(
            "space-#{space.hash}",
            "#{embed.hash}/thumbnail.jpg"
          )
      })

    now = DateTime.utc_now() |> DateTime.truncate(:second)
    bucket = "space-#{space.hash}"

    assert {:ok, _} =
             FlowStorageAdapterStub.put(
               bucket,
               "#{embed.hash}/poster.jpg",
               "generated-poster",
               "image/jpeg",
               space.region
             )

    assert {:ok, _} =
             FlowStorageAdapterStub.put(
               bucket,
               "#{embed.hash}/thumbnail.jpg",
               "custom-thumb",
               "image/jpeg",
               space.region
             )

    Repo.insert_all("renditions", [
      %{
        id: MaveCore.LegacyShortUUID.dump!(Ecto.UUID.generate()),
        video_id: MaveCore.LegacyShortUUID.dump!(embed.asset.current_video_id),
        rendition_key: "#{embed.hash}/poster.jpg",
        type: "poster",
        codec: nil,
        container: "jpg",
        size: nil,
        progress: 100.0,
        file_size: 15,
        inserted_at: now,
        updated_at: now
      },
      %{
        id: MaveCore.LegacyShortUUID.dump!(Ecto.UUID.generate()),
        video_id: MaveCore.LegacyShortUUID.dump!(embed.asset.current_video_id),
        rendition_key: "#{embed.hash}/thumbnail.jpg",
        type: "custom_thumbnail",
        codec: nil,
        container: "jpg",
        size: nil,
        progress: 100.0,
        file_size: 12,
        inserted_at: now,
        updated_at: now
      }
    ])

    assert {:ok, updated_embed} = Embeds.delete_external_poster(embed)

    assert updated_embed.settings.external_poster == nil

    assert {:ok, "generated-poster"} =
             FlowStorageAdapterStub.get(bucket, "#{embed.hash}/thumbnail.jpg", space.region)

    rendition_rows =
      Repo.all(
        from(r in "renditions",
          where: r.video_id == type(^embed.asset.current_video_id, MaveCore.Ecto.LegacyShortUUID),
          select: {r.type, r.rendition_key}
        )
      )

    assert {"thumbnail", "#{embed.hash}/thumbnail.jpg"} in rendition_rows
    refute Enum.any?(rendition_rows, fn {type, _key} -> type == "custom_thumbnail" end)
  end

  test "update_subtitle_outputs renames the public subtitle and republishes the manifest" do
    old_storage_adapter = Application.get_env(:mave_core, :flow_storage_adapter)
    Application.put_env(:mave_core, :flow_storage_adapter, FlowStorageAdapterStub)
    FlowStorageAdapterStub.reset!()

    on_exit(fn ->
      FlowStorageAdapterStub.reset!()

      if old_storage_adapter do
        Application.put_env(:mave_core, :flow_storage_adapter, old_storage_adapter)
      else
        Application.delete_env(:mave_core, :flow_storage_adapter)
      end
    end)

    space = space_fixture()

    embed =
      video_embed_fixture(space, %{name: "Update Subtitle Outputs"})
      |> Repo.preload([:space, :settings, asset: [:current_video]])

    subtitle =
      %Subtitle{}
      |> Subtitle.changeset(%{
        video_id: embed.asset.current_video_id,
        language: "nl",
        path: "#{embed.hash}/subtitle_nl.vtt"
      })
      |> Repo.insert!()

    bucket = "space-#{space.hash}"

    assert {:ok, _} =
             FlowStorageAdapterStub.put(
               bucket,
               "#{embed.hash}/subtitle_nl.vtt",
               "WEBVTT\n\n1\n00:00:00.000 --> 00:00:01.000\nHallo wereld\n",
               "text/vtt",
               space.region
             )

    assert {:ok, updated_subtitle} =
             MaveCore.Assets.update_subtitle_outputs(embed, subtitle, %{language: "en"})

    assert updated_subtitle.language == "en"
    assert updated_subtitle.path == "#{embed.hash}/subtitle_en.vtt"

    assert {:ok, body} =
             FlowStorageAdapterStub.get(bucket, "#{embed.hash}/subtitle_en.vtt", space.region)

    assert body =~ "Hallo wereld"

    assert {:ok, manifest_body} =
             FlowStorageAdapterStub.get(bucket, "#{embed.hash}/manifest.json", space.region)

    manifest = Jason.decode!(manifest_body)

    assert [
             %{
               "language" => "en",
               "label" => "English",
               "path" => subtitle_url
             }
           ] = manifest["subtitles"]

    expected_url =
      SettingsSerializer.storage_object_url(bucket, "#{embed.hash}/subtitle_en.vtt")

    assert String.starts_with?(subtitle_url, expected_url <> "?e=")
  end

  test "subtitle output mutations reject subtitles from another video" do
    space = space_fixture()

    embed =
      video_embed_fixture(space, %{name: "Scoped Subtitle Target"})
      |> Repo.preload([:space, :settings, asset: [:current_video]])

    foreign_space = space_fixture()

    foreign_embed =
      video_embed_fixture(foreign_space, %{name: "Foreign Scoped Subtitle"})
      |> Repo.preload([:space, :settings, asset: [:current_video]])

    foreign_subtitle =
      %Subtitle{}
      |> Subtitle.changeset(%{
        video_id: foreign_embed.asset.current_video_id,
        language: "en",
        path: "#{foreign_embed.hash}/subtitle_en.vtt"
      })
      |> Repo.insert!()

    assert {:error, :subtitle_not_found} =
             MaveCore.Assets.update_subtitle_outputs(embed, foreign_subtitle, %{language: "nl"})

    assert {:error, :subtitle_not_found} =
             MaveCore.Assets.delete_subtitle_outputs(embed, foreign_subtitle)

    assert %Subtitle{} = unchanged_subtitle = Repo.get(Subtitle, foreign_subtitle.id)
    assert unchanged_subtitle.video_id == foreign_subtitle.video_id
    assert unchanged_subtitle.language == "en"
    assert unchanged_subtitle.path == foreign_subtitle.path
  end

  test "delete_subtitle_outputs republishes the manifest without the removed subtitle" do
    old_storage_adapter = Application.get_env(:mave_core, :flow_storage_adapter)
    Application.put_env(:mave_core, :flow_storage_adapter, FlowStorageAdapterStub)
    FlowStorageAdapterStub.reset!()

    on_exit(fn ->
      FlowStorageAdapterStub.reset!()

      if old_storage_adapter do
        Application.put_env(:mave_core, :flow_storage_adapter, old_storage_adapter)
      else
        Application.delete_env(:mave_core, :flow_storage_adapter)
      end
    end)

    space = space_fixture()

    embed =
      video_embed_fixture(space, %{name: "Delete Subtitle Outputs"})
      |> Repo.preload([:space, :settings, asset: [:current_video]])

    subtitle =
      %Subtitle{}
      |> Subtitle.changeset(%{
        video_id: embed.asset.current_video_id,
        language: "en",
        path: "#{embed.hash}/subtitle_en.vtt"
      })
      |> Repo.insert!()

    bucket = "space-#{space.hash}"
    now = DateTime.utc_now() |> DateTime.truncate(:microsecond)

    Repo.insert_all("renditions", [
      %{
        id: MaveCore.LegacyShortUUID.dump!(Ecto.UUID.generate()),
        video_id: MaveCore.LegacyShortUUID.dump!(embed.asset.current_video_id),
        rendition_key: "#{embed.hash}/h264_sd_hls/playlist.m3u8",
        type: "video",
        codec: "h264",
        container: "hls",
        size: "sd",
        progress: 100.0,
        file_size: 123,
        inserted_at: now,
        updated_at: now
      }
    ])

    assert {:ok, _} =
             FlowStorageAdapterStub.put(
               bucket,
               "#{embed.hash}/subtitle_en.vtt",
               "WEBVTT\n\n1\n00:00:00.000 --> 00:00:01.000\nHello world\n",
               "text/vtt",
               space.region
             )

    assert {:ok, _deleted_subtitle} = MaveCore.Assets.delete_subtitle_outputs(embed, subtitle)
    assert Repo.get(Subtitle, subtitle.id) == nil

    assert {:ok, manifest_body} =
             FlowStorageAdapterStub.get(bucket, "#{embed.hash}/manifest.json", space.region)

    manifest = Jason.decode!(manifest_body)
    assert manifest["subtitles"] == []

    assert {:ok, playlist_body} =
             FlowStorageAdapterStub.get(
               bucket,
               "#{embed.hash}/playlist.m3u8",
               space.region
             )

    refute playlist_body =~ "TYPE=SUBTITLES"
    refute playlist_body =~ ~s(SUBTITLES="subtitles")
  end

  test "begin_video_upload resets timestamp poster settings on replacement" do
    space = space_fixture()

    embed =
      video_embed_fixture(space, %{name: "Replace Timestamp Poster"})
      |> Repo.preload([:space, :settings, asset: [:current_video]])

    original_video_id = embed.asset.current_video.id

    {:ok, embed} =
      Embeds.update_settings(embed, %{
        poster: :timecode,
        poster_time_hour: 0,
        poster_time_minute: 0,
        poster_time_second: 12.5
      })

    assert {:ok, updated_embed} =
             Embeds.begin_video_upload(space.hash, embed.hash, %{
               "title" => "Replacement Upload.mp4",
               "source_url" => "http://storage.local/replacement.mp4",
               "upload_size" => 1234
             })

    assert updated_embed.settings.poster == :upload
    assert updated_embed.settings.poster_time_seconds == nil
    assert updated_embed.settings.external_poster == nil
    assert updated_embed.asset.current_video.status == "uploading"
    refute updated_embed.asset.current_video.id == original_video_id
    assert Embeds.current_video_version(updated_embed) == 1

    assert Repo.aggregate(
             Ecto.assoc(updated_embed.asset, :videos),
             :count,
             :id
           ) == 2
  end

  test "begin_video_upload preserves a custom uploaded thumbnail on replacement" do
    space = space_fixture()

    embed =
      video_embed_fixture(space, %{name: "Replace Custom Thumbnail"})
      |> Repo.preload([:space, :settings, asset: [:current_video]])

    original_video_id = embed.asset.current_video.id

    custom_poster =
      SettingsSerializer.storage_object_url("space-#{space.hash}", "#{embed.hash}/thumbnail.jpg")

    {:ok, embed} =
      Embeds.update_settings(embed, %{
        poster: :upload,
        external_poster: custom_poster
      })

    assert {:ok, updated_embed} =
             Embeds.begin_video_upload(space.hash, embed.hash, %{
               "title" => "Replacement Upload.mp4",
               "source_url" => "http://storage.local/replacement.mp4",
               "upload_size" => 1234
             })

    assert updated_embed.settings.poster == :upload
    assert updated_embed.settings.external_poster == custom_poster
    assert updated_embed.asset.current_video.status == "uploading"
    refute updated_embed.asset.current_video.id == original_video_id
    assert Embeds.current_video_version(updated_embed) == 1
  end

  test "publish_settings materializes timestamp thumbnail files at current version and root" do
    old_storage_adapter = Application.get_env(:mave_core, :flow_storage_adapter)
    old_thumbnail_image_processor = Application.get_env(:mave_core, :thumbnail_image_processor)
    old_cdn_cache_purger = Application.get_env(:mave_core, :cdn_cache_purger)

    test_pid = self()

    Application.put_env(:mave_core, :flow_storage_adapter, FlowStorageAdapterStub)
    Application.put_env(:mave_core, :thumbnail_image_processor, TimecodeThumbnailImageProcessor)

    Application.put_env(:mave_core, :cdn_cache_purger, fn space_hash, region, paths ->
      send(test_pid, {:purged, space_hash, region, paths})
      :ok
    end)

    FlowStorageAdapterStub.reset!()

    on_exit(fn ->
      restore_env(:flow_storage_adapter, old_storage_adapter)
      restore_env(:thumbnail_image_processor, old_thumbnail_image_processor)
      restore_env(:cdn_cache_purger, old_cdn_cache_purger)
      FlowStorageAdapterStub.reset!()
    end)

    space = space_fixture()
    space_hash = space.hash

    embed =
      video_embed_fixture(space, %{name: "Timestamp Thumbnail"})
      |> Repo.preload([:space, :settings, asset: [:current_video]])

    assert {:ok, replacement_embed} =
             Embeds.begin_video_upload(space.hash, embed.hash, %{
               "title" => "Replacement Upload.mp4",
               "source_url" => "http://storage.local/replacement.mp4",
               "upload_size" => 1234
             })

    assert Embeds.current_video_version(replacement_embed) == 1

    assert {:ok, published_embed} =
             Embeds.publish_settings(replacement_embed, %{
               poster: :timecode,
               poster_time_second: 12.5
             })

    bucket = "space-#{space.hash}"

    for format <- ["jpg", "webp", "avif"] do
      body = "thumbnail #{format} at 12.5"
      root_key = "#{embed.hash}/thumbnail.#{format}"
      version_key = "#{embed.hash}/v1/custom_thumbnail.#{format}"

      assert {:ok, ^body} = FlowStorageAdapterStub.get(bucket, root_key, space.region)
      assert {:ok, ^body} = FlowStorageAdapterStub.get(bucket, version_key, space.region)
      assert FlowStorageAdapterStub.public?(bucket, root_key, space.region) == true
      assert FlowStorageAdapterStub.public?(bucket, version_key, space.region) == true
    end

    rendition_rows =
      from(r in "renditions",
        where:
          r.video_id ==
            type(^published_embed.asset.current_video.id, MaveCore.Ecto.LegacyShortUUID),
        where: r.type == "custom_thumbnail",
        select: {r.rendition_key, r.container}
      )
      |> Repo.all()

    assert {"#{embed.hash}/thumbnail.jpg", "jpg"} in rendition_rows
    assert {"#{embed.hash}/thumbnail.webp", "webp"} in rendition_rows
    assert {"#{embed.hash}/thumbnail.avif", "avif"} in rendition_rows

    assert {:ok, manifest_json} =
             FlowStorageAdapterStub.get(bucket, "#{embed.hash}/manifest.json", space.region)

    manifest = Jason.decode!(manifest_json)

    assert manifest["poster"]["image_src"] ==
             SettingsSerializer.storage_object_url(bucket, "#{embed.hash}/thumbnail.jpg")

    assert manifest["settings"]["poster"] == 12.5

    assert_received {:purged, ^space_hash, _region, purged_paths}
    assert "#{embed.hash}/thumbnail.jpg" in purged_paths
    assert "#{embed.hash}/v1/custom_thumbnail.jpg" in purged_paths
  end

  test "get_video_dashboard_payload accepts integer progress values from successful flow renditions" do
    space = space_fixture()
    video = video_embed_fixture(space, %{name: "Integer Progress Video"})

    Repo.get!(Asset, video.asset_id)
    |> Ecto.Changeset.change(current_video_id: nil)
    |> Repo.update!()

    processing_video =
      %Video{}
      |> Video.changeset(%{
        asset_id: video.asset_id,
        status: "uploading",
        file_name: "integer-progress.mp4",
        original_file_size: 12_345
      })
      |> Repo.insert!()

    Repo.get!(Asset, video.asset_id)
    |> Ecto.Changeset.change(current_video_id: processing_video.id)
    |> Repo.update!()

    {:ok, template} =
      Flow.create_template(%{
        "slug" => "integer-progress-#{System.unique_integer([:positive])}",
        "name" => "Integer Progress"
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
      status: "succeeded",
      attempt: 1,
      input: %{"params" => %{"codec" => "h264", "size" => "sd"}},
      output: %{
        "status" => "ok",
        "renditions" => [
          %{
            "id" => Ecto.UUID.generate(),
            "type" => "video",
            "container" => "hls",
            "codec" => "h264",
            "size" => "sd",
            "progress" => 100
          }
        ]
      }
    })
    |> Repo.insert!()

    payload = Embeds.get_video_dashboard_payload(space, video)

    assert Enum.any?(payload.renditions, fn rendition ->
             rendition.container == "hls" and rendition.progress == 100
           end)
  end

  test "get_video_dashboard_payload applies transcode progress to pending HLS renditions" do
    space = space_fixture()
    video = video_embed_fixture(space, %{name: "Live Progress Video"})

    Repo.get!(Asset, video.asset_id)
    |> Ecto.Changeset.change(current_video_id: nil)
    |> Repo.update!()

    processing_video =
      %Video{}
      |> Video.changeset(%{
        asset_id: video.asset_id,
        status: "uploading",
        file_name: "live-progress.mp4",
        original_file_size: 12_345
      })
      |> Repo.insert!()

    Repo.get!(Asset, video.asset_id)
    |> Ecto.Changeset.change(current_video_id: processing_video.id)
    |> Repo.update!()

    {:ok, template} =
      Flow.create_template(%{
        "slug" => "live-progress-#{System.unique_integer([:positive])}",
        "name" => "Live Progress"
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
      step_id: "video_h264_sd",
      step_type: "media.transcode_video",
      status: "executing",
      attempt: 1,
      input: %{"params" => %{"codec" => "h264", "size" => "sd", "container" => "mp4"}},
      execution_metadata: %{
        "progress" => %{
          "source" => "ffmpeg",
          "stage" => "transcode",
          "percent" => 37.2
        }
      }
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

    payload = Embeds.get_video_dashboard_payload(space, video)

    assert Enum.any?(payload.renditions, fn rendition ->
             rendition.container == "hls" and rendition.status == "executing" and
               rendition.phase == "encoding" and rendition.progress == 31
           end)
  end

  test "get_video_dashboard_payload applies ladder progress to pending HLS renditions" do
    space = space_fixture()
    video = video_embed_fixture(space, %{name: "Ladder Progress Video"})

    Repo.get!(Asset, video.asset_id)
    |> Ecto.Changeset.change(current_video_id: nil)
    |> Repo.update!()

    processing_video =
      %Video{}
      |> Video.changeset(%{
        asset_id: video.asset_id,
        status: "playable",
        file_name: "ladder-progress.mp4",
        original_file_size: 12_345
      })
      |> Repo.insert!()

    Repo.get!(Asset, video.asset_id)
    |> Ecto.Changeset.change(current_video_id: processing_video.id)
    |> Repo.update!()

    {:ok, template} =
      Flow.create_template(%{
        "slug" => "ladder-progress-#{System.unique_integer([:positive])}",
        "name" => "Ladder Progress"
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
      step_id: "inspect_media",
      step_type: "media.inspect",
      status: "succeeded",
      attempt: 1,
      output: %{
        "status" => "ok",
        "has_video" => true,
        "has_audio" => true,
        "width" => 1920,
        "height" => 1080
      }
    })
    |> Repo.insert!()

    ladder_step =
      %StepRun{}
      |> StepRun.changeset(%{
        flow_run_id: run.id,
        step_id: "video_h264_ladder",
        step_type: "media.transcode_h264_ladder",
        status: "executing",
        attempt: 1,
        input: %{"params" => %{"sizes" => ["sd", "hd"], "container" => "mp4"}}
      })
      |> Repo.insert!()

    %StepRun{}
    |> StepRun.changeset(%{
      flow_run_id: run.id,
      step_id: "hls_h264_hd",
      step_type: "media.package_hls_variant",
      status: "queued",
      attempt: 0,
      input: %{"params" => %{"codec" => "h264", "size" => "hd"}}
    })
    |> Repo.insert!()

    payload = Embeds.get_video_dashboard_payload(space, video)

    assert Enum.any?(payload.renditions, fn rendition ->
             rendition.container == "hls" and rendition.size_key == "hd" and
               rendition.status == "executing" and rendition.phase == "encoding" and
               rendition.progress == 1
           end)

    ladder_step
    |> StepRun.changeset(%{
      execution_metadata: %{
        "progress" => %{
          "source" => "encoding_booster",
          "stage" => "transcode",
          "percent" => 42.6
        }
      }
    })
    |> Repo.update!()

    payload = Embeds.get_video_dashboard_payload(space, video)

    assert Enum.any?(payload.renditions, fn rendition ->
             rendition.container == "hls" and rendition.size_key == "hd" and
               rendition.status == "executing" and rendition.phase == "encoding" and
               rendition.progress == 37
           end)

    ladder_step
    |> StepRun.changeset(%{status: "scheduled"})
    |> Repo.update!()

    payload = Embeds.get_video_dashboard_payload(space, video)

    assert Enum.any?(payload.renditions, fn rendition ->
             rendition.container == "mp4" and rendition.size_key == "hd" and
               rendition.status == "scheduled" and rendition.progress == 43
           end)

    assert Enum.any?(payload.renditions, fn rendition ->
             rendition.container == "hls" and rendition.size_key == "hd" and
               rendition.status == "executing" and rendition.phase == "encoding" and
               rendition.progress == 37
           end)

    ladder_step
    |> StepRun.changeset(%{
      status: "scheduled",
      execution_metadata: %{
        "progress" => %{
          "source" => "ffmpeg",
          "stage" => "package_hls",
          "percent" => 42.6
        }
      }
    })
    |> Repo.update!()

    payload = Embeds.get_video_dashboard_payload(space, video)

    assert Enum.any?(payload.renditions, fn rendition ->
             rendition.container == "hls" and rendition.size_key == "hd" and
               rendition.status == "executing" and rendition.phase == "packaging" and
               rendition.progress == 91
           end)
  end

  test "get_video_dashboard_payload builds the planned work from inspected media" do
    space = space_fixture()
    video = video_embed_fixture(space, %{name: "720p Progress Video"})

    Repo.get!(Asset, video.asset_id)
    |> Ecto.Changeset.change(current_video_id: nil)
    |> Repo.update!()

    processing_video =
      %Video{}
      |> Video.changeset(%{
        asset_id: video.asset_id,
        status: "uploading",
        file_name: "720p-progress.mp4",
        original_file_size: 12_345
      })
      |> Repo.insert!()

    Repo.get!(Asset, video.asset_id)
    |> Ecto.Changeset.change(current_video_id: processing_video.id)
    |> Repo.update!()

    {:ok, template} =
      Flow.create_template(%{
        "slug" => "720p-progress-#{System.unique_integer([:positive])}",
        "name" => "720p Progress"
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
      step_id: "inspect_media",
      step_type: "media.inspect",
      status: "succeeded",
      attempt: 1,
      output: %{
        "status" => "ok",
        "has_video" => true,
        "has_audio" => true,
        "width" => 1280,
        "height" => 720,
        "duration" => 10.0
      }
    })
    |> Repo.insert!()

    %StepRun{}
    |> StepRun.changeset(%{
      flow_run_id: run.id,
      step_id: "video_h264_qhd",
      step_type: "media.transcode_h264_ladder",
      status: "queued",
      attempt: 0,
      input: %{
        "params" => %{
          "sizes" => ["qhd"],
          "container" => "mp4",
          "require_source_resolution" => true
        }
      }
    })
    |> Repo.insert!()

    for size <- ["sd", "hd", "fhd", "qhd", "uhd"] do
      %StepRun{}
      |> StepRun.changeset(%{
        flow_run_id: run.id,
        step_id: "clip_hevc_#{size}",
        step_type: "media.transcode_video",
        status: "queued",
        attempt: 0,
        input: %{
          "params" => %{
            "codec" => "hevc",
            "size" => size,
            "conditional_size" => true,
            "keyframe_interval" => 250
          }
        }
      })
      |> Repo.insert!()
    end

    %StepRun{}
    |> StepRun.changeset(%{
      flow_run_id: run.id,
      step_id: "poster_frame",
      step_type: "media.extract_frame",
      status: "queued",
      attempt: 0,
      input: %{"params" => %{"role" => "poster", "codec" => "jpg"}}
    })
    |> Repo.insert!()

    %StepRun{}
    |> StepRun.changeset(%{
      flow_run_id: run.id,
      step_id: "transcribe_audio",
      step_type: "ai.transcribe_audio",
      status: "executing",
      attempt: 1,
      input: %{"params" => %{}}
    })
    |> Repo.insert!()

    %StepRun{}
    |> StepRun.changeset(%{
      flow_run_id: run.id,
      step_id: "video_h264_ladder",
      step_type: "media.transcode_h264_ladder",
      status: "executing",
      attempt: 1,
      input: %{"params" => %{"sizes" => ["sd", "hd", "fhd", "qhd", "uhd"], "container" => "mp4"}},
      execution_metadata: %{
        "progress" => %{"source" => "ffmpeg", "stage" => "transcode", "percent" => 51.0}
      }
    })
    |> Repo.insert!()

    for size <- ["sd", "hd", "fhd", "qhd", "uhd"] do
      %StepRun{}
      |> StepRun.changeset(%{
        flow_run_id: run.id,
        step_id: "hls_h264_#{size}",
        step_type: "media.package_hls_variant",
        status: "queued",
        attempt: 0,
        input: %{
          "params" => %{
            "codec" => "h264",
            "size" => size,
            "source_step_id" => "video_h264_ladder"
          }
        }
      })
      |> Repo.insert!()
    end

    payload = Embeds.get_video_dashboard_payload(space, video)

    hls_sizes =
      payload.renditions
      |> Enum.filter(&(&1.container == "hls"))
      |> Enum.map(& &1.size_key)

    assert "sd" in hls_sizes
    assert "hd" in hls_sizes
    refute "fhd" in hls_sizes
    refute "qhd" in hls_sizes
    refute "uhd" in hls_sizes

    refute Enum.any?(payload.renditions, &(&1.container == "mp4" and &1.size_key == "qhd"))

    clip_sizes =
      payload.renditions
      |> Enum.filter(&(&1.type == "clip" and &1.codec_key == "hevc"))
      |> Enum.map(& &1.size_key)

    assert Enum.sort(clip_sizes) == ["hd", "sd"]
    assert Enum.any?(payload.renditions, &(&1.type == "poster" and &1.codec == "JPG"))

    assert Enum.any?(payload.renditions, fn rendition ->
             rendition.type == "subtitle" and rendition.status == "executing" and
               rendition.label == "Subtitles"
           end)
  end

  test "get_video_dashboard_payload combines HLS packaging progress with completed transcode progress" do
    space = space_fixture()
    video = video_embed_fixture(space, %{name: "Combined HLS Progress Video"})

    Repo.get!(Asset, video.asset_id)
    |> Ecto.Changeset.change(current_video_id: nil)
    |> Repo.update!()

    processing_video =
      %Video{}
      |> Video.changeset(%{
        asset_id: video.asset_id,
        status: "uploading",
        file_name: "combined-hls-progress.mp4",
        original_file_size: 12_345
      })
      |> Repo.insert!()

    Repo.get!(Asset, video.asset_id)
    |> Ecto.Changeset.change(current_video_id: processing_video.id)
    |> Repo.update!()

    {:ok, template} =
      Flow.create_template(%{
        "slug" => "combined-hls-progress-#{System.unique_integer([:positive])}",
        "name" => "Combined HLS Progress"
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
      step_id: "video_h264_sd",
      step_type: "media.transcode_video",
      status: "succeeded",
      attempt: 1,
      input: %{"params" => %{"codec" => "h264", "size" => "sd", "container" => "mp4"}}
    })
    |> Repo.insert!()

    %StepRun{}
    |> StepRun.changeset(%{
      flow_run_id: run.id,
      step_id: "hls_h264_sd",
      step_type: "media.package_hls_variant",
      status: "executing",
      attempt: 1,
      input: %{"params" => %{"codec" => "h264", "size" => "sd"}},
      execution_metadata: %{
        "progress" => %{
          "source" => "ffmpeg",
          "stage" => "package_hls",
          "percent" => 12.0
        }
      }
    })
    |> Repo.insert!()

    payload = Embeds.get_video_dashboard_payload(space, video)

    assert Enum.any?(payload.renditions, fn rendition ->
             rendition.container == "hls" and rendition.size_key == "sd" and
               rendition.status == "executing" and rendition.phase == "packaging" and
               rendition.progress == 87
           end)
  end

  test "get_video_dashboard_payload enters packaging phase when transcode completes" do
    space = space_fixture()
    video = video_embed_fixture(space, %{name: "HLS Packaging Start Progress Video"})

    Repo.get!(Asset, video.asset_id)
    |> Ecto.Changeset.change(current_video_id: nil)
    |> Repo.update!()

    processing_video =
      %Video{}
      |> Video.changeset(%{
        asset_id: video.asset_id,
        status: "uploading",
        file_name: "hls-packaging-start-progress.mp4",
        original_file_size: 12_345
      })
      |> Repo.insert!()

    Repo.get!(Asset, video.asset_id)
    |> Ecto.Changeset.change(current_video_id: processing_video.id)
    |> Repo.update!()

    {:ok, template} =
      Flow.create_template(%{
        "slug" => "hls-packaging-start-progress-#{System.unique_integer([:positive])}",
        "name" => "HLS Packaging Start Progress"
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
      step_id: "video_h264_sd",
      step_type: "media.transcode_video",
      status: "succeeded",
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

    payload = Embeds.get_video_dashboard_payload(space, video)

    assert Enum.any?(payload.renditions, fn rendition ->
             rendition.container == "hls" and rendition.size_key == "sd" and
               rendition.status == "executing" and rendition.phase == "packaging" and
               rendition.progress == 85
           end)
  end

  test "get_video_dashboard_payload includes flow summary for the latest run" do
    space = space_fixture()
    video = video_embed_fixture(space, %{name: "Flow Summary Video"})

    {:ok, template} =
      Flow.create_template(%{
        "slug" => "flow-summary-#{System.unique_integer([:positive])}",
        "name" => "Flow Summary"
      })

    {:ok, version} =
      Flow.create_version(template.id, %{
        "definition" => %{
          "steps" => [
            %{"id" => "source", "type" => "source.resolve", "name" => "Resolve Source"},
            %{
              "id" => "poster",
              "type" => "media.extract_frame",
              "name" => "Extract Poster",
              "depends_on" => ["source"],
              "lane" => "fast",
              "required" => false
            },
            %{
              "id" => "manifest",
              "type" => "manifest.build",
              "name" => "Build Manifest",
              "depends_on" => ["source", "poster"],
              "lane" => "background"
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
      step_id: "poster",
      step_type: "media.extract_frame",
      status: "failed",
      attempt: 1,
      input: %{},
      error: "timeout",
      completed_at: DateTime.utc_now() |> DateTime.truncate(:microsecond)
    })
    |> Repo.insert!()

    %StepRun{}
    |> StepRun.changeset(%{
      flow_run_id: run.id,
      step_id: "manifest",
      step_type: "manifest.build",
      status: "scheduled",
      attempt: 1,
      input: %{}
    })
    |> Repo.insert!()

    for index <- 1..12 do
      %Run{}
      |> Run.changeset(%{
        flow_template_id: template.id,
        flow_version_id: version.id,
        status: "succeeded",
        input: %{
          "space_hash" => space.hash,
          "embed_hash" => "other#{String.pad_leading(Integer.to_string(index), 5, "0")}"
        },
        context: %{}
      })
      |> Repo.insert!()
    end

    handler_id = {__MODULE__, self(), System.unique_integer([:positive])}

    :ok =
      :telemetry.attach(
        handler_id,
        [:mave_core, :repo, :query],
        &__MODULE__.count_flow_run_query/4,
        nil
      )

    on_exit(fn -> :telemetry.detach(handler_id) end)
    Process.put(:flow_run_query_count, 0)
    Process.put(:flow_run_queries, [])

    payload = Embeds.get_video_dashboard_payload(space, video)

    assert Process.get(:flow_run_query_count) == 1, inspect(Process.get(:flow_run_queries))
    assert payload.flow.template_slug == template.slug
    assert payload.flow.version == version.version
    assert payload.flow.status == "running"
    assert payload.flow.active_step.name == "Build Manifest"
    assert payload.flow.summary.failed == 1
    assert payload.flow.summary.scheduled == 1

    assert Enum.any?(payload.flow.steps, fn step ->
             step.name == "Extract Poster" and step.lane == "fast" and step.required == false
           end)

    video.asset.current_video
    |> Video.changeset(%{status: "uploading"})
    |> Repo.update!()

    %{videos: rows} = Embeds.list_root_items(space)
    row = Enum.find(rows, &(&1.uuid == video.id))

    assert row.state == :queued
  end

  test "get_video_dashboard_payload includes persisted audio tracks" do
    space = space_fixture()
    video = video_embed_fixture(space, %{name: "Audio Track Payload"})

    current_video =
      %Video{}
      |> Video.changeset(%{
        asset_id: video.asset_id,
        status: "ready",
        file_name: "audio-track-payload.mp4",
        original_file_size: 12_345
      })
      |> Repo.insert!()

    Repo.get!(Asset, video.asset_id)
    |> Ecto.Changeset.change(current_video_id: current_video.id)
    |> Repo.update!()

    %AudioTrack{}
    |> AudioTrack.changeset(%{
      video_id: current_video.id,
      label: "Original",
      language: "en",
      default: true,
      codec: "mp3",
      file_size: 4_321,
      filename: "audio.mp3"
    })
    |> Repo.insert!()

    payload = Embeds.get_video_dashboard_payload(space, video)

    assert [%{label: "Original", language: "en", codec: "MP3", filename: "audio.mp3"}] =
             payload.audio_tracks
  end

  describe "rename_embed" do
    setup do
      old_storage_adapter = Application.get_env(:mave_core, :flow_storage_adapter)
      old_cache_purger = Application.get_env(:mave_core, :cdn_cache_purger)
      Application.put_env(:mave_core, :flow_storage_adapter, FlowStorageAdapterStub)
      FlowStorageAdapterStub.reset!()
      test_pid = self()

      Application.put_env(:mave_core, :cdn_cache_purger, fn space_hash, region, paths ->
        send(test_pid, {:purged, space_hash, region, paths})
        :ok
      end)

      on_exit(fn ->
        restore_env(:flow_storage_adapter, old_storage_adapter)
        restore_env(:cdn_cache_purger, old_cache_purger)
        FlowStorageAdapterStub.reset!()
      end)

      :ok
    end

    test "rename_embed updates video asset names and folder names" do
      space = space_fixture()
      video = video_embed_fixture(space, %{name: "Before Video"})
      folder = folder_embed_fixture(space, %{name: "Before Folder"})

      assert {:ok, renamed_video} = Embeds.rename_embed(video, "After Video")
      assert {:ok, renamed_folder} = Embeds.rename_embed(folder, "After Folder")

      assert renamed_video.asset.name == "After Video"
      assert renamed_folder.collection.name == "After Folder"

      bucket = "space-#{space.hash}"
      key = "#{video.hash}/manifest.json"
      assert {:ok, body} = FlowStorageAdapterStub.get(bucket, key, space.region)
      assert Jason.decode!(body)["name"] == "After Video"

      assert {:error, _} =
               FlowStorageAdapterStub.get(bucket, "#{folder.hash}/manifest.json", space.region)

      assert {:ok, blank_video} = Embeds.rename_embed(renamed_video, "")
      assert is_nil(blank_video.asset.name)
      assert {:ok, body} = FlowStorageAdapterStub.get(bucket, key, space.region)
      assert Jason.decode!(body)["name"] == "Before Video.mp4"
    end

    test "republishes the name in both audio manifests and purges their cache" do
      space = space_fixture()
      embed = video_embed_fixture(space, %{name: "Before Audio"})

      audio =
        %Video{}
        |> Video.changeset(%{asset_id: embed.asset_id, status: "ready", file_name: "episode.mp3"})
        |> Repo.insert!()

      embed.asset
      |> Ecto.Changeset.change(current_video_id: audio.id)
      |> Repo.update!()

      bucket = "space-#{space.hash}"
      keys = ["#{embed.hash}/v1/manifest.json", "#{embed.hash}/manifest.json"]

      previous = %{
        "name" => "Before Audio",
        "video" => %{"version" => 1, "audio" => true},
        "waveform" => %{"version" => 1, "peaks" => [0.1, 0.8]}
      }

      for key <- keys do
        FlowStorageAdapterStub.put_public(
          bucket,
          key,
          Jason.encode!(previous),
          "application/json",
          space.region
        )
      end

      assert {:ok, renamed} = Embeds.rename_embed(embed, "  After Audio  ")
      assert renamed.asset.name == "After Audio"

      for key <- keys do
        assert {:ok, body} = FlowStorageAdapterStub.get(bucket, key, space.region)
        manifest = Jason.decode!(body)
        assert manifest["name"] == "After Audio"
        assert manifest["video"]["filetype"] == "mp3"
        assert manifest["video"]["max_width"] == nil
        assert manifest["waveform"] == previous["waveform"]
      end

      assert_receive {:purged, space_hash, region, paths}
      assert space_hash == space.hash
      assert region == space.region
      assert Enum.all?(keys, &(&1 in paths))
    end

    test "returns publication failures without broadcasting a successful rename" do
      space = space_fixture()
      embed = video_embed_fixture(space, %{name: "Before Video"})
      Events.subscribe(space.id, embed.id)

      FlowStorageAdapterStub.fail_public_put!(
        "space-#{space.hash}",
        "#{embed.hash}/manifest.json",
        space.region
      )

      assert {:error, {:manifest_upload_failed, :synthetic_put_failure}} =
               Embeds.rename_embed(embed, "After Video")

      refute_receive {:embed_updated, _}
      refute_receive {:purged, _, _, _}
    end
  end

  test "archive_embed removes video collection membership and toggles archived state" do
    space = space_fixture()
    folder = folder_embed_fixture(space, %{name: "Archive Folder"})
    video = video_embed_fixture(space, %{name: "Archive Video"})

    link_embed_to_folder(folder, video)

    assert {:ok, archived_video} = Embeds.archive_embed(video)
    assert archived_video.archived
    assert Repo.aggregate(CollectionEmbed, :count, :id) == 0

    assert {:ok, unarchived_video} = Embeds.archive_embed(archived_video)
    refute unarchived_video.archived
    assert Repo.aggregate(CollectionEmbed, :count, :id) == 0
  end

  test "archive_embed recurses through nested folder trees" do
    space = space_fixture()
    folder_a = folder_embed_fixture(space, %{name: "Folder A"})
    folder_b = folder_embed_fixture(space, %{name: "Folder B"})
    video = video_embed_fixture(space, %{name: "Nested Video"})

    link_embed_to_folder(folder_a, folder_b)
    link_embed_to_folder(folder_b, video)

    assert {:ok, archived_folder} = Embeds.archive_embed(folder_a)
    assert archived_folder.archived
    assert Repo.get!(Embed, folder_b.id).archived
    assert Repo.get!(Embed, video.id).archived

    assert {:ok, unarchived_folder} = Embeds.archive_embed(archived_folder)
    refute unarchived_folder.archived
    refute Repo.get!(Embed, folder_b.id).archived
    refute Repo.get!(Embed, video.id).archived
  end

  test "move_embed moves videos and folders between root and folders while preventing cycles" do
    space = space_fixture()
    folder_a = folder_embed_fixture(space, %{name: "Folder A"})
    folder_b = folder_embed_fixture(space, %{name: "Folder B"})
    child_folder = folder_embed_fixture(space, %{name: "Child Folder"})
    video = video_embed_fixture(space, %{name: "Move Video"})

    link_embed_to_folder(folder_a, video)
    link_embed_to_folder(folder_a, child_folder)

    assert {:ok, moved_video} = Embeds.move_embed(video, folder_b)
    assert moved_video.id == video.id

    memberships =
      Repo.all(
        from(ce in CollectionEmbed, where: ce.embed_id == ^video.id, select: ce.collection_id)
      )

    assert memberships == [folder_b.collection_id]

    assert {:ok, _root_video} = Embeds.remove_embed_from_folder(video)

    assert Repo.aggregate(
             from(ce in CollectionEmbed, where: ce.embed_id == ^video.id),
             :count,
             :id
           ) == 0

    assert {:error, :invalid_target_folder} = Embeds.move_embed(folder_a, child_folder)
  end

  test "create embeds can place new records directly inside a parent folder" do
    space = space_fixture()
    folder = folder_embed_fixture(space, %{name: "Parent Folder"})

    assert {:ok, video} = Embeds.create_video_embed(space, %{parent_folder_id: folder.id})
    assert {:ok, child_folder} = Embeds.create_folder_embed(space, %{parent_folder_id: folder.id})

    linked_ids =
      Repo.all(
        from(ce in CollectionEmbed,
          where: ce.collection_id == ^folder.collection_id,
          select: ce.embed_id
        )
      )

    assert video.id in linked_ids
    assert child_folder.id in linked_ids
  end

  test "folder breadcrumbs terminate even for preexisting cycles" do
    space = space_fixture()
    folder_a = folder_embed_fixture(space, %{name: "Folder A"})
    folder_b = folder_embed_fixture(space, %{name: "Folder B"})
    folder_c = folder_embed_fixture(space, %{name: "Folder C"})

    link_embed_to_folder(folder_a, folder_b)
    link_embed_to_folder(folder_b, folder_c)
    assert Enum.map(Embeds.folder_paths(space, folder_c), & &1.id) == [folder_a.id, folder_b.id]

    link_embed_to_folder(folder_c, folder_a)
    assert Enum.map(Embeds.folder_paths(space, folder_c), & &1.id) == [folder_a.id, folder_b.id]
  end

  test "list_folder_targets excludes the moving folder and descendants" do
    space = space_fixture()
    folder_a = folder_embed_fixture(space, %{name: "Folder A"})
    folder_b = folder_embed_fixture(space, %{name: "Folder B"})
    child_folder = folder_embed_fixture(space, %{name: "Child Folder"})

    link_embed_to_folder(folder_a, child_folder)

    targets = Embeds.list_folder_targets(space, :all, folder_a)

    assert Enum.any?(targets, &(&1.id == folder_b.id))
    refute Enum.any?(targets, &(&1.id == folder_a.id))
    refute Enum.any?(targets, &(&1.id == child_folder.id))
  end

  test "delete_embed soft deletes videos and folder delete keeps children" do
    space = space_fixture()
    folder = folder_embed_fixture(space, %{name: "Delete Folder"})
    video = video_embed_fixture(space, %{name: "Delete Video"})
    child_video = video_embed_fixture(space, %{name: "Child Survives"})

    link_embed_to_folder(folder, child_video)

    assert {:ok, deleted_video} = Embeds.delete_embed(video)
    assert Repo.get!(Embed, deleted_video.id).deleted_at

    assert {:ok, _deleted_folder} = Embeds.delete_embed(folder)
    refute Repo.get(Embed, folder.id)
    assert Repo.get!(Embed, child_video.id)
    assert Repo.aggregate(CollectionEmbed, :count, :id) == 0
  end

  test "delete_space_videos deletes every active video including archived and nested videos" do
    space =
      space_fixture()
      |> Ecto.Changeset.change(region: "eu_2")
      |> Repo.update!()

    other_space = space_fixture()
    active_video = video_embed_fixture(space, %{name: "Active Video"})
    archived_video = video_embed_fixture(space, %{name: "Archived Video", archived: true})
    folder = folder_embed_fixture(space, %{name: "Video Folder"})
    nested_video = video_embed_fixture(space, %{name: "Nested Video"})
    other_video = video_embed_fixture(other_space, %{name: "Other Space Video"})

    link_embed_to_folder(folder, nested_video)

    assert {:ok, deleted_embeds} = Embeds.delete_space_videos(space)

    assert MapSet.new(Enum.map(deleted_embeds, & &1.id)) ==
             MapSet.new([active_video.id, archived_video.id, nested_video.id])

    assert Repo.get!(Embed, active_video.id).deleted_at
    assert Repo.get!(Embed, archived_video.id).deleted_at
    assert Repo.get!(Embed, nested_video.id).deleted_at
    refute Repo.get!(Embed, folder.id).deleted_at
    refute Repo.get!(Embed, other_video.id).deleted_at
  end

  test "delete_space_videos skips previously deleted videos and is safe to retry" do
    space =
      space_fixture()
      |> Ecto.Changeset.change(region: "eu_2")
      |> Repo.update!()

    previously_deleted = video_embed_fixture(space, %{name: "Previously Deleted"})
    remaining_video = video_embed_fixture(space, %{name: "Remaining Video"})

    assert {:ok, _embed} = Embeds.delete_embed(previously_deleted)
    assert {:ok, [deleted_embed]} = Embeds.delete_space_videos(space)
    assert deleted_embed.id == remaining_video.id
    assert {:ok, []} = Embeds.delete_space_videos(space)
  end

  test "delete_embed sets video assets to private before soft delete" do
    original_storage_module = Application.get_env(:mave_core, :storage_module)

    Application.put_env(:mave_core, :storage_module, FlowStorageAdapterStub)
    FlowStorageAdapterStub.reset!()

    on_exit(fn ->
      if is_nil(original_storage_module) do
        Application.delete_env(:mave_core, :storage_module)
      else
        Application.put_env(:mave_core, :storage_module, original_storage_module)
      end
    end)

    space =
      space_fixture()
      |> Ecto.Changeset.change(region: "eu")
      |> Repo.update!()

    video = video_embed_fixture(space, %{name: "Delete Private Visibility"})

    assert {:ok, _deleted_video} = Embeds.delete_embed(video)

    assert FlowStorageAdapterStub.visibility(space.hash, video.hash, "eu") ==
             "private"
  end

  test "delete_embed soft deletes videos on storage profiles without object ACLs" do
    original_storage_module = Application.get_env(:mave_core, :storage_module)
    Application.delete_env(:mave_core, :storage_module)

    on_exit(fn -> restore_env(:storage_module, original_storage_module) end)

    space =
      space_fixture()
      |> Ecto.Changeset.change(region: "eu_2")
      |> Repo.update!()

    video = video_embed_fixture(space, %{name: "Delete Without Object ACLs"})

    assert {:ok, deleted_video} = Embeds.delete_embed(video)
    assert Repo.get!(Embed, deleted_video.id).deleted_at
  end

  test "delete_embed cancels active flow runs for the video" do
    space = space_fixture()
    video = video_embed_fixture(space, %{name: "Delete Cancels Flow"})

    {:ok, template} =
      Flow.create_template(%{
        "slug" => "delete-cancels-flow-#{System.unique_integer([:positive])}",
        "name" => "Delete Cancels Flow"
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
      Flow.start_run(
        template.id,
        %{"space_hash" => space.hash, "embed_hash" => video.hash},
        enqueue: false,
        version: version.version
      )

    assert run.status == "running"
    assert Enum.all?(run.step_runs, &(&1.status == "queued"))

    assert {:ok, _deleted_video} = Embeds.delete_embed(video)

    cancelled_run = Flow.get_run!(run.id)
    assert cancelled_run.status == "cancelled"
    assert cancelled_run.error == "embed deleted"
    assert Enum.all?(cancelled_run.step_runs, &(&1.status == "cancelled"))
  end

  test "settings serializer supports local components base url and explicit src overrides" do
    original_src = Application.get_env(:mave_core, :components_src)
    original_base = Application.get_env(:mave_core, :components_base_url)
    original_domain = Application.get_env(:mave_core, :domain)
    original_upload = Application.get_env(:mave_core, :upload)
    original_cdn_host = Application.get_env(:mave_core, :public_cdn_host)
    original_cdn_scheme = Application.get_env(:mave_core, :public_cdn_scheme)
    original_metrics_host = System.get_env("MAVE_METRICS_HOST")

    on_exit(fn ->
      restore_env(:components_src, original_src)
      restore_env(:components_base_url, original_base)
      restore_env(:domain, original_domain)
      restore_env(:upload, original_upload)
      restore_env(:public_cdn_host, original_cdn_host)
      restore_env(:public_cdn_scheme, original_cdn_scheme)

      case original_metrics_host do
        nil -> System.delete_env("MAVE_METRICS_HOST")
        value -> System.put_env("MAVE_METRICS_HOST", value)
      end
    end)

    Application.delete_env(:mave_core, :components_src)
    Application.put_env(:mave_core, :components_base_url, "http://localhost:8888/")

    assert SettingsSerializer.component_src() == "http://localhost:8888/dist/index.js"
    assert SettingsSerializer.component_config_src() == "http://localhost:8888/dist/config.js"
    assert SettingsSerializer.react_src() == "http://localhost:8888/dist/react.js"
    assert SettingsSerializer.vue_src() == "http://localhost:8888/dist/vue.js"

    Application.delete_env(:mave_core, :components_base_url)

    Application.put_env(
      :mave_core,
      :components_src,
      "http://cdn.orb.local/npm/@maveio/components/+esm"
    )

    assert SettingsSerializer.component_config_src() ==
             "http://cdn.orb.local/npm/@maveio/components/dist/config.js"

    assert SettingsSerializer.react_src() ==
             "http://cdn.orb.local/npm/@maveio/components/dist/react.js"

    assert SettingsSerializer.vue_src() ==
             "http://cdn.orb.local/npm/@maveio/components/dist/vue.js"

    Application.delete_env(:mave_core, :components_src)
    Application.delete_env(:mave_core, :components_base_url)
    Application.put_env(:mave_core, :domain, "https://dashboard.example.test/")

    Application.put_env(:mave_core, :upload,
      endpoint: "https://upload.example.test/files",
      source_base_url: "https://storage.example.test",
      source_region: "fr-par",
      hook_secret: "secret",
      default_template: "publish_default"
    )

    Application.put_env(:mave_core, :public_cdn_host, "storage.example.test")
    Application.put_env(:mave_core, :public_cdn_scheme, "https")
    System.put_env("MAVE_METRICS_HOST", "metrics.example.test")

    assert SettingsSerializer.component_src() ==
             "https://cdn.video-dns.com/npm/@maveio/components/+esm"

    assert SettingsSerializer.component_config_src() ==
             "https://cdn.video-dns.com/npm/@maveio/components/dist/config.js"

    assert Jason.decode!(SettingsSerializer.component_config_json()) == %{
             "api" => %{"endpoint" => "https://dashboard.example.test/api/v1"},
             "cdn" => %{
               "endpoint" => "https://space-${this.spaceId}.storage.example.test",
               "playback_endpoint" =>
                 "https://dashboard.example.test/api/v1/playback/media/${this.spaceId}${this.embedId}"
             },
             "metrics" => %{"endpoint" => "https://metrics.example.test/v1/events"},
             "upload" => %{
               "endpoint" => "https://upload.example.test/files",
               "socket" => "wss://dashboard.example.test/api/v1/socket"
             }
           }

    assert SettingsSerializer.storage_object_url("space-ofyrn", "Vkmazex4WB/manifest.json") ==
             "https://space-ofyrn.storage.example.test/Vkmazex4WB/manifest.json"
  end

  test "settings serializer does not require component config for production CDN aliases" do
    original_playback_origin = Application.get_env(:mave_core, :playback_origin)
    original_src = Application.get_env(:mave_core, :components_src)
    original_base = Application.get_env(:mave_core, :components_base_url)
    original_domain = Application.get_env(:mave_core, :domain)
    original_upload = Application.get_env(:mave_core, :upload)
    original_cdn_host = Application.get_env(:mave_core, :public_cdn_host)
    original_cdn_scheme = Application.get_env(:mave_core, :public_cdn_scheme)
    original_cdn_mode = Application.get_env(:mave_core, :public_cdn_mode)
    original_api_host = System.get_env("MAVE_API_HOST")
    original_metrics_host = System.get_env("MAVE_METRICS_HOST")

    on_exit(fn ->
      restore_env(:playback_origin, original_playback_origin)
      restore_env(:components_src, original_src)
      restore_env(:components_base_url, original_base)
      restore_env(:domain, original_domain)
      restore_env(:upload, original_upload)
      restore_env(:public_cdn_host, original_cdn_host)
      restore_env(:public_cdn_scheme, original_cdn_scheme)
      restore_env(:public_cdn_mode, original_cdn_mode)
      restore_system_env("MAVE_API_HOST", original_api_host)
      restore_system_env("MAVE_METRICS_HOST", original_metrics_host)
    end)

    Application.put_env(:mave_core, :playback_origin, "https://signed.video-dns.com")
    Application.delete_env(:mave_core, :components_src)
    Application.delete_env(:mave_core, :components_base_url)
    Application.put_env(:mave_core, :domain, "https://dash.mave.io")

    Application.put_env(:mave_core, :upload,
      endpoint: "https://upload.mave.io/files",
      source_base_url: "https://storage.example.test",
      public_base_url: "https://storage.mave.io",
      source_region: "fr-par",
      hook_secret: "secret",
      default_template: "publish_default"
    )

    Application.put_env(:mave_core, :public_cdn_host, "video-dns.com")
    Application.put_env(:mave_core, :public_cdn_scheme, "https")
    System.put_env("MAVE_API_HOST", "api.mave.io")
    System.put_env("MAVE_METRICS_HOST", "metrics.video-dns.com")

    Application.delete_env(:mave_core, :public_cdn_mode)

    assert Jason.decode!(SettingsSerializer.component_config_json())["cdn"]["endpoint"] ==
             "https://space-${this.spaceId}.video-dns.com"

    refute SettingsSerializer.component_config_required?()

    Application.put_env(:mave_core, :public_cdn_mode, "path")

    assert Jason.decode!(SettingsSerializer.component_config_json())["cdn"]["endpoint"] ==
             "https://cdn.video-dns.com/space-${this.spaceId}"

    refute SettingsSerializer.component_config_required?()
  end

  test "settings serializer uses path-style public object urls for local saas" do
    original_cdn_host = Application.get_env(:mave_core, :public_cdn_host)
    original_cdn_scheme = Application.get_env(:mave_core, :public_cdn_scheme)
    original_cdn_mode = Application.get_env(:mave_core, :public_cdn_mode)

    on_exit(fn ->
      restore_env(:public_cdn_host, original_cdn_host)
      restore_env(:public_cdn_scheme, original_cdn_scheme)
      restore_env(:public_cdn_mode, original_cdn_mode)
    end)

    Application.put_env(:mave_core, :public_cdn_host, "saas.orb.local")
    Application.put_env(:mave_core, :public_cdn_scheme, "https")
    Application.delete_env(:mave_core, :public_cdn_mode)

    assert SettingsSerializer.storage_object_url("space-lt1ij", "yrATPMmNde/poster.jpg") ==
             "https://cdn.saas.orb.local/space-lt1ij/yrATPMmNde/poster.jpg"

    config = Jason.decode!(SettingsSerializer.component_config_json())

    assert config["cdn"]["playback_endpoint"] ==
             "http://localhost:4000/api/v1/playback/media/${this.spaceId}${this.embedId}"

    config = update_in(config, ["cdn"], &Map.delete(&1, "playback_endpoint"))

    assert config == %{
             "api" => %{"endpoint" => "http://localhost:4000/api/v1"},
             "cdn" => %{"endpoint" => "https://cdn.saas.orb.local/space-${this.spaceId}"},
             "metrics" => %{"endpoint" => "http://localhost:4000/v1/events"},
             "upload" => %{
               "endpoint" => "http://localhost:1080/files",
               "socket" => "ws://localhost:4000/api/v1/socket"
             }
           }

    assert SettingsSerializer.iframe_url("lt1ij", "yrATPMmNde") ==
             "https://cdn.saas.orb.local/space-lt1ij/yrATPMmNde/player.html"
  end

  test "settings serializer supports an explicit path-style object storage base URL" do
    original_cdn_base_url = Application.get_env(:mave_core, :public_cdn_base_url)

    on_exit(fn -> restore_env(:public_cdn_base_url, original_cdn_base_url) end)

    Application.put_env(:mave_core, :public_cdn_base_url, "http://localhost:9000/")

    assert SettingsSerializer.storage_object_url("space-lt1ij", "video/manifest.json") ==
             "http://localhost:9000/space-lt1ij/video/manifest.json"

    assert Jason.decode!(SettingsSerializer.component_config_json())["cdn"]["endpoint"] ==
             "http://localhost:9000/space-${this.spaceId}"
  end

  test "settings serializer honors explicit path-style public CDN mode" do
    original_cdn_host = Application.get_env(:mave_core, :public_cdn_host)
    original_cdn_scheme = Application.get_env(:mave_core, :public_cdn_scheme)
    original_cdn_mode = Application.get_env(:mave_core, :public_cdn_mode)

    on_exit(fn ->
      restore_env(:public_cdn_host, original_cdn_host)
      restore_env(:public_cdn_scheme, original_cdn_scheme)
      restore_env(:public_cdn_mode, original_cdn_mode)
    end)

    Application.put_env(:mave_core, :public_cdn_host, "video-dns.com")
    Application.put_env(:mave_core, :public_cdn_scheme, "https")
    Application.put_env(:mave_core, :public_cdn_mode, "path")

    assert SettingsSerializer.storage_object_url("space-ubg50", "XiyviR3oEq/thumbnail.jpg") ==
             "https://cdn.video-dns.com/space-ubg50/XiyviR3oEq/thumbnail.jpg"

    assert Jason.decode!(SettingsSerializer.component_config_json())["cdn"]["endpoint"] ==
             "https://cdn.video-dns.com/space-${this.spaceId}"
  end

  test "settings serializer uses public upload base for legacy uploaded poster keys" do
    original_upload = Application.get_env(:mave_core, :upload)

    on_exit(fn ->
      restore_env(:upload, original_upload)
    end)

    Application.put_env(:mave_core, :upload,
      endpoint: "https://upload.mave.io/files",
      source_base_url: "https://s3.fr-par.scw.cloud",
      public_base_url: "https://storage.mave.io",
      source_region: "fr-par",
      hook_secret: "secret",
      default_template: "publish_default"
    )

    settings = %MaveCore.Embeds.EmbedSettings{
      poster: :upload,
      external_poster: "887a04d0106075a693946da135f89461"
    }

    assert SettingsSerializer.preview_poster_url(
             %Space{hash: "ubg50"},
             %Embed{hash: "XiyviR3oEq"},
             settings
           ) == "https://storage.mave.io/887a04d0106075a693946da135f89461"
  end

  test "video dashboard thumbnail preview uses generated thumbnails and public hls url on staging" do
    original_domain = Application.get_env(:mave_core, :domain)
    original_upload = Application.get_env(:mave_core, :upload)
    original_cdn_host = Application.get_env(:mave_core, :public_cdn_host)
    original_cdn_scheme = Application.get_env(:mave_core, :public_cdn_scheme)

    on_exit(fn ->
      restore_env(:domain, original_domain)
      restore_env(:upload, original_upload)
      restore_env(:public_cdn_host, original_cdn_host)
      restore_env(:public_cdn_scheme, original_cdn_scheme)
    end)

    Application.put_env(:mave_core, :domain, "https://dash.staging.mave.io/")

    Application.put_env(:mave_core, :upload,
      endpoint: "https://upload.staging.mave.io/files",
      source_base_url: "https://s3.fr-par.scw.cloud",
      source_region: "fr-par",
      hook_secret: "secret",
      default_template: "publish_default"
    )

    Application.put_env(:mave_core, :public_cdn_host, "staging.video-dns.com")
    Application.put_env(:mave_core, :public_cdn_scheme, "https")

    space = space_fixture()
    video = video_embed_fixture(space, %{name: "Preview Video"})
    current_video = video.asset.current_video
    now = DateTime.utc_now() |> DateTime.truncate(:second)

    Repo.insert_all("renditions", [
      %{
        id: MaveCore.LegacyShortUUID.dump!(Ecto.UUID.generate()),
        video_id: MaveCore.LegacyShortUUID.dump!(current_video.id),
        rendition_key: "#{video.hash}/h264_sd_hls/playlist.m3u8",
        type: "video",
        codec: "h264",
        container: "hls",
        size: "sd",
        progress: 100.0,
        file_size: 374,
        inserted_at: now,
        updated_at: now
      }
    ])

    payload = Embeds.get_video_dashboard_payload(space, video)

    assert payload.thumbnail_preview.preferred_src ==
             "https://space-#{space.hash}.s3.fr-par.scw.cloud/#{video.hash}/h264_sd_hls/playlist.m3u8"

    assert payload.thumbnail_preview.fallback_src ==
             "https://space-#{space.hash}.s3.fr-par.scw.cloud/#{video.hash}/original"

    assert Enum.map(payload.thumbnail_preview.frame_srcs, & &1.src) == [
             "https://space-#{space.hash}.s3.fr-par.scw.cloud/#{video.hash}/thumbnail_0.jpg",
             "https://space-#{space.hash}.s3.fr-par.scw.cloud/#{video.hash}/thumbnail_1.jpg",
             "https://space-#{space.hash}.s3.fr-par.scw.cloud/#{video.hash}/thumbnail_2.jpg",
             "https://space-#{space.hash}.s3.fr-par.scw.cloud/#{video.hash}/thumbnail_3.jpg",
             "https://space-#{space.hash}.s3.fr-par.scw.cloud/#{video.hash}/thumbnail_4.jpg",
             "https://space-#{space.hash}.s3.fr-par.scw.cloud/#{video.hash}/thumbnail_5.jpg"
           ]

    private_video =
      video
      |> Ecto.Changeset.change(playback_visibility: :private, playback_status: :private)
      |> Repo.update!()

    preview = Embeds.get_video_dashboard_payload(space, private_video).thumbnail_preview
    playlist = URI.parse(preview.preferred_src)
    token = URI.decode_query(playlist.query)["token"]
    assert is_binary(token)

    assert String.ends_with?(playlist.path, "/#{video.hash}/h264_sd_hls/playlist.m3u8") or
             String.ends_with?(
               playlist.path,
               "/#{space.hash}#{video.hash}/h264_sd_hls/playlist.m3u8"
             )

    assert {:ok, _expires_at} = MaveCore.Playback.authorize(token, private_video)

    for src <- [preview.fallback_src | Enum.map(preview.frame_srcs, & &1.src)] do
      uri = URI.parse(src)
      query = URI.decode_query(uri.query)
      assert query["X-Amz-Signature"]
      assert query["X-Amz-Expires"] == "86400"
      assert String.contains?(uri.path, "/#{video.hash}/")
    end
  end

  test "settings serializer omits default controls from player attrs but keeps manifest default" do
    settings = SettingsSerializer.settings_struct(nil)

    refute {"controls", "full"} in SettingsSerializer.player_attributes(settings)
    assert SettingsSerializer.manifest_settings(settings)["controls"] == "full"
    assert SettingsSerializer.manifest_settings(settings)["width"] == nil
    assert SettingsSerializer.manifest_settings(settings)["height"] == nil
    assert SettingsSerializer.manifest_settings(settings)["loop"] == nil
    assert SettingsSerializer.manifest_settings(settings)["autoplay"] == nil
    assert SettingsSerializer.manifest_settings(settings)["poster"] == nil

    assert SettingsSerializer.attributes_to_string(SettingsSerializer.player_attributes(settings)) ==
             ""
  end

  test "settings serializer keeps quotes and markup inside attribute values" do
    value = ~s(a"<img/src='https://example.com/pixel'>&)

    rendered =
      ~s(<mave-player #{SettingsSerializer.attributes_to_string([{"width", value}])}></mave-player>)

    document = LazyHTML.from_fragment(rendered)

    assert LazyHTML.query(document, "img") |> LazyHTML.to_tree() == []
    assert LazyHTML.query(document, "mave-player") |> LazyHTML.attribute("width") == [value]
  end

  test "settings serializer renders loop as a bare attribute like old mave" do
    settings =
      SettingsSerializer.settings_struct(%MaveCore.Embeds.EmbedSettings{loop_enabled: true})

    assert {"loop", "loop"} in SettingsSerializer.player_attributes(settings)

    assert SettingsSerializer.attributes_to_string(SettingsSerializer.player_attributes(settings)) ==
             "loop"
  end

  test "video dashboard payload thumbnail uses the public thumbnail rendition" do
    space = space_fixture()
    video = video_embed_fixture(space, %{name: "Thumbnail Video"})

    payload = Embeds.get_video_dashboard_payload(space, video)

    assert payload.thumbnail ==
             SettingsSerializer.storage_object_url(
               "space-#{space.hash}",
               "#{video.hash}/thumbnail.jpg"
             )
  end

  test "video dashboard preview uses the completed public thumbnail instead of the image API" do
    space = space_fixture()
    video = video_embed_fixture(space, %{name: "Completed Thumbnail Preview"})
    inserted_at = ~U[2026-01-02 03:04:05Z]

    Repo.insert_all("renditions", [
      %{
        id: MaveCore.LegacyShortUUID.dump!(Ecto.UUID.generate()),
        video_id: MaveCore.LegacyShortUUID.dump!(video.asset.current_video_id),
        rendition_key: "#{video.hash}/thumbnail.jpg",
        type: "thumbnail",
        codec: nil,
        container: "jpg",
        size: nil,
        progress: 100.0,
        file_size: 1_000,
        inserted_at: inserted_at,
        updated_at: inserted_at
      }
    ])

    payload = Embeds.get_video_dashboard_payload(space, video)

    expected =
      SettingsSerializer.storage_object_url(
        "space-#{space.hash}",
        "#{video.hash}/thumbnail.jpg"
      ) <> "?e=#{DateTime.to_unix(inserted_at, :microsecond)}"

    assert payload.preview_poster == expected
    refute payload.preview_poster =~ "image.mave.io"
  end

  test "video dashboard payload cache-busts completed custom thumbnail URLs" do
    space = space_fixture()
    video = video_embed_fixture(space, %{name: "Custom Thumbnail Video"})

    thumbnail_url =
      SettingsSerializer.storage_object_url("space-#{space.hash}", "#{video.hash}/thumbnail.jpg")

    {:ok, video} =
      Embeds.update_settings(video, %{
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

    payload = Embeds.get_video_dashboard_payload(space, video)

    versioned_thumbnail_url =
      "#{thumbnail_url}?e=#{DateTime.to_unix(inserted_at, :microsecond)}"

    assert payload.thumbnail == versioned_thumbnail_url
    assert payload.preview_poster == versioned_thumbnail_url
    assert payload.snippet_player_poster == versioned_thumbnail_url
  end

  test "dashboard video rows cache-bust completed custom thumbnail URLs" do
    space = space_fixture()
    video = video_embed_fixture(space, %{name: "Custom Row Thumbnail Video"})

    thumbnail_url =
      SettingsSerializer.storage_object_url("space-#{space.hash}", "#{video.hash}/thumbnail.jpg")

    {:ok, video} =
      Embeds.update_settings(video, %{
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

    %{videos: rows} = Embeds.list_root_items(space)
    row = Enum.find(rows, &(&1.uuid == video.id))

    assert row.thumb ==
             "#{thumbnail_url}?e=#{DateTime.to_unix(inserted_at, :microsecond)}"
  end

  test "dashboard video rows cache-bust completed generated thumbnail URLs" do
    space = space_fixture()
    video = video_embed_fixture(space, %{name: "Generated Row Thumbnail Video"})

    thumbnail_url =
      SettingsSerializer.storage_object_url("space-#{space.hash}", "#{video.hash}/thumbnail.jpg")

    inserted_at = ~U[2026-01-02 03:04:05.123456Z]

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

    %{videos: rows} = Embeds.list_root_items(space)
    row = Enum.find(rows, &(&1.uuid == video.id))

    assert row.thumb ==
             "#{thumbnail_url}?e=#{DateTime.to_unix(inserted_at, :microsecond)}"
  end

  test "video search suggestions use the public thumbnail rendition" do
    space = space_fixture()
    video = video_embed_fixture(space, %{name: "Search Thumbnail Video"})

    [suggestion] = Embeds.search_video_suggestions(space, "Search Thumbnail", limit: 1)

    assert suggestion.thumb ==
             SettingsSerializer.storage_object_url(
               "space-#{space.hash}",
               "#{video.hash}/thumbnail.jpg"
             )

    refute suggestion.thumb =~ "#{space.hash}#{video.hash}.webp"
  end

  test "video dashboard payload thumbnail stays on public rendition when preview poster uses selected timecode" do
    space = space_fixture()
    video = video_embed_fixture(space, %{name: "Timecode Thumbnail Video"})

    {:ok, video} =
      Embeds.update_settings(video, %{
        poster: :timecode,
        poster_time_second: 12.5
      })

    payload = Embeds.get_video_dashboard_payload(space, video)

    assert payload.thumbnail ==
             SettingsSerializer.storage_object_url(
               "space-#{space.hash}",
               "#{video.hash}/thumbnail.jpg"
             )

    assert payload.preview_poster =~ "#{space.hash}#{video.hash}.webp?time=12.5"
  end

  defp space_fixture do
    email = "embeds-test-#{System.unique_integer([:positive])}@example.com"
    {:ok, user} = Accounts.create_user(email)
    user.current_space_membership.space
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
        max_frame_rate: 29.97,
        max_bitrate: 12_000_000,
        duration: 52.3,
        aspect_ratio: "16/9",
        original_file_size: 245_000_000
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
    |> Repo.preload(asset: [:current_video])
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
    |> Repo.preload(:collection)
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

  defp restore_env(key, nil), do: Application.delete_env(:mave_core, key)
  defp restore_env(key, value), do: Application.put_env(:mave_core, key, value)
  defp restore_system_env(key, nil), do: System.delete_env(key)
  defp restore_system_env(key, value), do: System.put_env(key, value)

  def count_flow_run_query(_event, _measurements, %{source: "flow_runs"} = metadata, _config) do
    Process.put(:flow_run_query_count, Process.get(:flow_run_query_count, 0) + 1)
    Process.put(:flow_run_queries, [metadata.query | Process.get(:flow_run_queries, [])])
  end

  def count_flow_run_query(_event, _measurements, _metadata, _config), do: :ok
end
