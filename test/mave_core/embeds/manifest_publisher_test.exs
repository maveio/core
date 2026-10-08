defmodule MaveCore.Embeds.ManifestPublisherTest do
  use MaveCore.DataCase, async: false

  alias MaveCore.Accounts
  alias MaveCore.Assets.{Asset, AudioTrack, Subtitle, Video}
  alias MaveCore.Embeds.{Embed, EmbedSettings, ManifestPublisher, SettingsSerializer}
  alias MaveCore.TestSupport.FlowStorageAdapterStub

  defmodule MissingBucketStorageAdapter do
    @moduledoc false
    use Agent

    def start_link(result), do: Agent.start_link(fn -> {false, result} end, name: __MODULE__)

    def get(bucket, key, region), do: FlowStorageAdapterStub.get(bucket, key, region)

    def ensure_bucket(_bucket, _region) do
      Agent.get_and_update(__MODULE__, fn {_exists, result} ->
        {result, {result == :ok, result}}
      end)
    end

    def put_public(bucket, key, body, content_type, region) do
      if Agent.get(__MODULE__, &elem(&1, 0)) do
        FlowStorageAdapterStub.put_public(bucket, key, body, content_type, region)
      else
        {:error, :not_found}
      end
    end
  end

  defmodule SerializedStorageAdapter do
    @moduledoc false

    alias MaveCore.TestSupport.FlowStorageAdapterStub

    def child_spec(_opts) do
      %{
        id: __MODULE__,
        start: {__MODULE__, :start_link, [[]]}
      }
    end

    def start_link(_opts) do
      Agent.start_link(
        fn -> %{active: 0, max_active: 0, puts: 0} end,
        name: __MODULE__
      )
    end

    def get(bucket, path, region), do: FlowStorageAdapterStub.get(bucket, path, region)

    def put_public(bucket, path, body, content_type, region) do
      Agent.update(__MODULE__, fn state ->
        active = state.active + 1

        %{
          state
          | active: active,
            max_active: max(state.max_active, active),
            puts: state.puts + 1
        }
      end)

      Process.sleep(50)
      FlowStorageAdapterStub.put_public(bucket, path, body, content_type, region)
    after
      Agent.update(__MODULE__, &Map.update!(&1, :active, fn active -> active - 1 end))
    end

    def stats, do: Agent.get(__MODULE__, & &1)
  end

  setup do
    old_storage_adapter = Application.get_env(:mave_core, :flow_storage_adapter)
    old_cache_purger = Application.get_env(:mave_core, :cdn_cache_purger)
    Application.put_env(:mave_core, :flow_storage_adapter, FlowStorageAdapterStub)
    Application.delete_env(:mave_core, :cdn_cache_purger)
    FlowStorageAdapterStub.reset!()

    on_exit(fn ->
      if old_storage_adapter do
        Application.put_env(:mave_core, :flow_storage_adapter, old_storage_adapter)
      else
        Application.delete_env(:mave_core, :flow_storage_adapter)
      end

      if old_cache_purger do
        Application.put_env(:mave_core, :cdn_cache_purger, old_cache_purger)
      else
        Application.delete_env(:mave_core, :cdn_cache_purger)
      end
    end)

    :ok
  end

  test "renaming a draft provisions its missing bucket before publishing" do
    start_supervised!({MissingBucketStorageAdapter, :ok})
    Application.put_env(:mave_core, :flow_storage_adapter, MissingBucketStorageAdapter)
    space = space_fixture()
    {:ok, embed} = MaveCore.Embeds.create_video_embed(space, %{name: "Draft"})

    assert {:ok, renamed} = MaveCore.Embeds.rename_embed(embed, "Renamed draft")
    assert renamed.asset.name == "Renamed draft"

    assert {:ok, body} =
             FlowStorageAdapterStub.get(
               "space-#{space.hash}",
               "#{embed.hash}/manifest.json",
               space.region
             )

    assert Jason.decode!(body)["name"] == "Renamed draft"
  end

  test "a missing bucket's provisioning failure remains a publication error" do
    start_supervised!({MissingBucketStorageAdapter, {:error, {:bucket_create_failed, 403}}})
    Application.put_env(:mave_core, :flow_storage_adapter, MissingBucketStorageAdapter)
    embed = manifest_embed_fixture()

    assert {:error, {:manifest_upload_failed, {:bucket_create_failed, 403}}} =
             ManifestPublisher.publish(embed)
  end

  test "publishes a canonical final manifest from persisted data" do
    space = space_fixture()

    settings =
      %EmbedSettings{}
      |> EmbedSettings.changeset(%{space_id: space.id})
      |> Repo.insert!()

    asset =
      %Asset{}
      |> Asset.changeset(%{space_id: space.id, name: "Canonical Asset"})
      |> Repo.insert!()

    video =
      %Video{}
      |> Video.changeset(%{
        asset_id: asset.id,
        status: "ready",
        file_name: "canonical.mp4",
        max_width: 1280,
        max_height: 720,
        duration: 8.0,
        aspect_ratio: "16:9",
        original_file_size: 1_849_672,
        language: "en"
      })
      |> Repo.insert!()

    asset
    |> Ecto.Changeset.change(current_video_id: video.id)
    |> Repo.update!()

    embed =
      %Embed{}
      |> Embed.changeset(%{
        space_id: space.id,
        asset_id: asset.id,
        embed_settings_id: settings.id,
        hash: unique_embed_hash(),
        type: :video,
        version: 2
      })
      |> Repo.insert!()
      |> Repo.preload([:space, :settings, asset: [:current_video]])

    audio_track =
      %AudioTrack{}
      |> AudioTrack.changeset(%{
        video_id: video.id,
        label: "Original",
        language: "en",
        default: true,
        codec: "mp3",
        file_size: 129_069,
        filename: "audio.mp3"
      })
      |> Repo.insert!()

    subtitle =
      %Subtitle{}
      |> Subtitle.changeset(%{
        video_id: video.id,
        language: "en",
        path: "#{embed.hash}/subtitle_en.vtt"
      })
      |> Repo.insert!()

    now = DateTime.utc_now()

    Repo.insert_all("renditions", [
      rendition_row(
        video.id,
        "#{embed.hash}/h264_sd_hls/playlist.m3u8",
        "video",
        "h264",
        "hls",
        "sd",
        1_895_537,
        now
      ),
      rendition_row(
        video.id,
        "#{embed.hash}/h264_sd.mp4",
        "video",
        "h264",
        "mp4",
        "sd",
        2_029_194,
        now
      ),
      rendition_row(
        video.id,
        "#{embed.hash}/h264_hd_hls/playlist.m3u8",
        "video",
        "h264",
        "hls",
        "hd",
        3_724_121,
        now
      ),
      rendition_row(
        video.id,
        "#{embed.hash}/h264_hd.mp4",
        "video",
        "h264",
        "mp4",
        "hd",
        3_857_786,
        now
      ),
      rendition_row(
        video.id,
        "#{embed.hash}/clip_keyframes_hd.mp4",
        "clip_keyframes",
        "h264",
        "mp4",
        "hd",
        5_336_981,
        now
      ),
      rendition_row(
        video.id,
        "#{embed.hash}/thumbnail.jpg",
        "thumbnail",
        nil,
        "jpg",
        nil,
        58_478,
        now
      ),
      rendition_row(video.id, "#{embed.hash}/poster.jpg", "poster", nil, "jpg", nil, 63_638, now)
    ])

    assert {:ok, manifest} = ManifestPublisher.publish(embed)

    refute Map.has_key?(manifest, "metrics_key")

    assert manifest["settings"] == %{
             "aspect_ratio" => "16 / 9",
             "width" => nil,
             "height" => nil,
             "loop" => nil,
             "autoplay" => nil,
             "color" => nil,
             "opacity" => nil,
             "controls" => "full",
             "poster" => nil
           }

    assert manifest["audio_tracks"] == [
             %{
               "id" => audio_track.id,
               "label" => "Original",
               "language" => "en",
               "default" => true,
               "codec" => "mp3",
               "file_size" => 129_069,
               "filename" => "audio.mp3",
               "path" =>
                 SettingsSerializer.storage_object_url(
                   "space-#{space.hash}",
                   "#{embed.hash}/audio.mp3"
                 )
             }
           ]

    assert manifest["subtitles"] == [
             %{
               "language" => "en",
               "label" => "English",
               "path" =>
                 SettingsSerializer.storage_object_url(
                   "space-#{space.hash}",
                   "#{embed.hash}/subtitle_en.vtt"
                 ) <> "?e=#{DateTime.to_unix(subtitle.updated_at, :microsecond)}"
             }
           ]

    next_updated_at = DateTime.add(subtitle.updated_at, 1, :second)
    Repo.update_all(Subtitle, set: [updated_at: next_updated_at])

    assert {:ok, updated_manifest} = ManifestPublisher.publish(embed)

    assert get_in(updated_manifest, ["subtitles", Access.at(0), "path"]) ==
             SettingsSerializer.storage_object_url(
               "space-#{space.hash}",
               "#{embed.hash}/subtitle_en.vtt"
             ) <> "?e=#{DateTime.to_unix(next_updated_at, :microsecond)}"

    assert manifest["poster"]["image_src"] ==
             SettingsSerializer.storage_object_url(
               "space-#{space.hash}",
               "#{embed.hash}/thumbnail.jpg"
             )

    assert manifest["video"]["version"] == 0
    assert manifest["video"]["id"] == video.id
    assert manifest["video"]["status"] == "ready"
    assert manifest["video"]["ready"] == true
    assert manifest["video"]["audio"] == true
    assert manifest["video"]["language"] == "en"
    assert manifest["video"]["max_width"] == 1280
    assert manifest["video"]["max_height"] == 720
    assert manifest["video"]["src"] == nil
    assert manifest["video"]["original"] == nil

    assert Enum.all?(manifest["video"]["renditions"], fn rendition ->
             Map.has_key?(rendition, "rendition_key") == false and
               Map.has_key?(rendition, "src") == false
           end)
  end

  test "prefers custom thumbnail poster images over generated thumbnails" do
    space = space_fixture()

    settings =
      %EmbedSettings{}
      |> EmbedSettings.changeset(%{
        space_id: space.id,
        poster: :upload,
        external_poster: "https://cdn.example.com/fallback.jpg"
      })
      |> Repo.insert!()

    asset =
      %Asset{}
      |> Asset.changeset(%{space_id: space.id, name: "Custom Poster Asset"})
      |> Repo.insert!()

    video =
      %Video{}
      |> Video.changeset(%{
        asset_id: asset.id,
        status: "ready",
        file_name: "custom-poster.mp4",
        max_width: 1280,
        max_height: 720,
        duration: 8.0,
        aspect_ratio: "16:9",
        original_file_size: 1_000,
        language: "en"
      })
      |> Repo.insert!()

    asset
    |> Ecto.Changeset.change(current_video_id: video.id)
    |> Repo.update!()

    embed =
      %Embed{}
      |> Embed.changeset(%{
        space_id: space.id,
        asset_id: asset.id,
        embed_settings_id: settings.id,
        hash: unique_embed_hash(),
        type: :video,
        version: 2
      })
      |> Repo.insert!()
      |> Repo.preload([:space, :settings, asset: [:current_video]])

    now = DateTime.utc_now()

    Repo.insert_all("renditions", [
      rendition_row(video.id, "#{embed.hash}/poster.jpg", "poster", nil, "jpg", nil, 10, now),
      rendition_row(
        video.id,
        "#{embed.hash}/thumbnail.jpg",
        "custom_thumbnail",
        nil,
        "jpg",
        nil,
        12,
        now
      )
    ])

    assert {:ok, manifest} = ManifestPublisher.publish(embed)

    assert manifest["poster"]["image_src"] ==
             SettingsSerializer.storage_object_url(
               "space-#{space.hash}",
               "#{embed.hash}/thumbnail.jpg"
             )
  end

  test "keeps the public thumbnail at the root for replacement versions" do
    space = space_fixture()

    settings =
      %EmbedSettings{}
      |> EmbedSettings.changeset(%{space_id: space.id})
      |> Repo.insert!()

    asset =
      %Asset{}
      |> Asset.changeset(%{space_id: space.id, name: "Replacement Asset"})
      |> Repo.insert!()

    _first_video =
      %Video{}
      |> Video.changeset(%{
        asset_id: asset.id,
        status: "ready",
        file_name: "first.mp4",
        max_width: 1280,
        max_height: 720,
        duration: 8.0,
        aspect_ratio: "16:9",
        original_file_size: 1_000
      })
      |> Repo.insert!()

    Process.sleep(5)

    replacement_video =
      %Video{}
      |> Video.changeset(%{
        asset_id: asset.id,
        status: "ready",
        file_name: "replacement.mp4",
        max_width: 1280,
        max_height: 720,
        duration: 8.0,
        aspect_ratio: "16:9",
        original_file_size: 2_000
      })
      |> Repo.insert!()

    asset
    |> Ecto.Changeset.change(current_video_id: replacement_video.id)
    |> Repo.update!()

    embed =
      %Embed{}
      |> Embed.changeset(%{
        space_id: space.id,
        asset_id: asset.id,
        embed_settings_id: settings.id,
        hash: unique_embed_hash(),
        type: :video,
        version: 2
      })
      |> Repo.insert!()
      |> Repo.preload([:space, :settings, asset: [:current_video]])

    now = DateTime.utc_now()

    Repo.insert_all("renditions", [
      rendition_row(
        replacement_video.id,
        "#{embed.hash}/v1/h264_sd.mp4",
        "video",
        "h264",
        "mp4",
        "sd",
        2_029_194,
        now
      ),
      rendition_row(
        replacement_video.id,
        "#{embed.hash}/v1/thumbnail.jpg",
        "thumbnail",
        nil,
        "jpg",
        nil,
        58_478,
        now
      )
    ])

    assert {:ok, manifest} = ManifestPublisher.publish(embed)

    assert manifest["video"]["version"] == 1

    assert manifest["poster"]["image_src"] ==
             SettingsSerializer.storage_object_url(
               "space-#{space.hash}",
               "#{embed.hash}/thumbnail.jpg"
             )
  end

  test "marks original as having audio before processed audio tracks exist when inspect found audio" do
    space = space_fixture()

    settings =
      %EmbedSettings{}
      |> EmbedSettings.changeset(%{space_id: space.id})
      |> Repo.insert!()

    asset =
      %Asset{}
      |> Asset.changeset(%{space_id: space.id, name: "Original With Audio"})
      |> Repo.insert!()

    video =
      %Video{}
      |> Video.changeset(%{
        asset_id: asset.id,
        status: "uploading",
        file_name: "original-with-audio.mp4",
        max_width: 1280,
        max_height: 720,
        duration: 8.0,
        aspect_ratio: "16:9",
        original_file_size: 1_849_672
      })
      |> Repo.insert!()

    asset
    |> Ecto.Changeset.change(current_video_id: video.id)
    |> Repo.update!()

    embed =
      %Embed{}
      |> Embed.changeset(%{
        space_id: space.id,
        asset_id: asset.id,
        embed_settings_id: settings.id,
        hash: unique_embed_hash(),
        type: :video
      })
      |> Repo.insert!()
      |> Repo.preload([:space, :settings, asset: [:current_video]])

    assert {:ok, manifest} =
             ManifestPublisher.publish(embed, %{
               "bucket" => "space-#{space.hash}",
               "original_key" => "#{embed.hash}/original",
               "has_audio" => true
             })

    assert manifest["audio_tracks"] == []
    assert manifest["video"]["audio"] == true

    assert manifest["video"]["src"] ==
             SettingsSerializer.storage_object_url(
               "space-#{space.hash}",
               "#{embed.hash}/original"
             )

    assert manifest["video"]["original"] ==
             SettingsSerializer.storage_object_url(
               "space-#{space.hash}",
               "#{embed.hash}/original"
             )
  end

  test "allows an intermediate manifest to advertise playable status before finalization" do
    space = space_fixture()

    settings =
      %EmbedSettings{}
      |> EmbedSettings.changeset(%{space_id: space.id})
      |> Repo.insert!()

    asset =
      %Asset{}
      |> Asset.changeset(%{space_id: space.id, name: "Playable Original"})
      |> Repo.insert!()

    video =
      %Video{}
      |> Video.changeset(%{
        asset_id: asset.id,
        status: "uploading",
        file_name: "playable-original.mp4",
        original_file_size: 512_000
      })
      |> Repo.insert!()

    asset
    |> Ecto.Changeset.change(current_video_id: video.id)
    |> Repo.update!()

    embed =
      %Embed{}
      |> Embed.changeset(%{
        space_id: space.id,
        asset_id: asset.id,
        embed_settings_id: settings.id,
        hash: unique_embed_hash(),
        type: :video
      })
      |> Repo.insert!()
      |> Repo.preload([:space, :settings, asset: [:current_video]])

    assert {:ok, manifest} =
             ManifestPublisher.publish(embed, %{
               "bucket" => "space-#{space.hash}",
               "original_key" => "#{embed.hash}/original",
               "status" => "playable"
             })

    assert manifest["video"]["status"] == "playable"
    assert manifest["video"]["ready"] == true
    assert manifest["video"]["audio"] == true

    assert manifest["video"]["src"] ==
             SettingsSerializer.storage_object_url(
               "space-#{space.hash}",
               "#{embed.hash}/original"
             )

    now = DateTime.utc_now()

    Repo.insert_all("renditions", [
      rendition_row(
        video.id,
        "#{embed.hash}/h264_sd.mp4",
        "video",
        "h264",
        "mp4",
        "sd",
        256_000,
        now
      ),
      rendition_row(
        video.id,
        "#{embed.hash}/h264_sd_hls/playlist.m3u8",
        "video",
        "h264",
        "hls",
        "sd",
        240_000,
        now
      )
    ])

    assert {:ok, refreshed_manifest} =
             ManifestPublisher.publish(embed, %{"status" => "playable"})

    assert refreshed_manifest["video"]["src"] == nil
    assert refreshed_manifest["video"]["original"] == nil
    assert refreshed_manifest["video"]["audio"] == true

    refute Enum.any?(refreshed_manifest["video"]["renditions"], fn rendition ->
             rendition["container"] == "hls"
           end)

    assert {:ok, hls_ready_manifest} =
             ManifestPublisher.publish(embed, %{"status" => "playable", "hls_ready" => true})

    assert Enum.any?(hls_ready_manifest["video"]["renditions"], fn rendition ->
             rendition["container"] == "hls" and rendition["size"] == "sd"
           end)

    assert hls_ready_manifest["video"]["src"] == nil
    assert hls_ready_manifest["video"]["original"] == nil

    assert {:ok, inspected_manifest} =
             ManifestPublisher.publish(embed, %{"status" => "playable", "has_audio" => false})

    assert inspected_manifest["video"]["audio"] == false
    assert inspected_manifest["video"]["src"] == nil
    assert inspected_manifest["video"]["original"] == nil
  end

  test "recovers HLS availability from the completed master after a stale manifest publication" do
    embed = manifest_embed_fixture()
    video = embed.asset.current_video
    now = DateTime.utc_now() |> DateTime.truncate(:second)

    master =
      rendition_row(
        video.id,
        "#{embed.hash}/playlist.m3u8",
        "video",
        "h264",
        "hls",
        nil,
        512,
        now
      )

    Repo.insert_all("renditions", [
      rendition_row(
        video.id,
        "#{embed.hash}/h264_hd_hls/playlist.m3u8",
        "video",
        "h264",
        "hls",
        "hd",
        1024,
        now
      ),
      Map.put(master, :progress, 50.0)
    ])

    assert {:ok, pending} = ManifestPublisher.publish(embed, %{"status" => "playable"})
    assert pending["video"]["renditions"] == []

    from(r in "renditions", where: r.rendition_key == ^master.rendition_key)
    |> Repo.update_all(set: [progress: 100.0])

    # The stored manifest still has no HLS and this publication has no hls_ready hint.
    assert {:ok, recovered} = ManifestPublisher.publish(embed, %{"status" => "playable"})
    assert [%{"container" => "hls", "size" => "hd"}] = recovered["video"]["renditions"]

    assert {:ok, refreshed} = ManifestPublisher.publish(embed, %{"status" => "playable"})
    assert refreshed["video"]["renditions"] == recovered["video"]["renditions"]
  end

  test "purges manifest keys and the embed prefix after publishing" do
    test_pid = self()

    Application.put_env(:mave_core, :cdn_cache_purger, fn space_hash, region, paths ->
      send(test_pid, {:purged, space_hash, region, paths})
      :ok
    end)

    space =
      space_fixture()
      |> Ecto.Changeset.change(region: "eu_2")
      |> Repo.update!()

    settings =
      %EmbedSettings{}
      |> EmbedSettings.changeset(%{space_id: space.id})
      |> Repo.insert!()

    asset =
      %Asset{}
      |> Asset.changeset(%{space_id: space.id, name: "Cache purge video"})
      |> Repo.insert!()

    video =
      %Video{}
      |> Video.changeset(%{
        asset_id: asset.id,
        status: "ready",
        duration: 6.0,
        file_name: "cache-purge.mp4",
        inserted_at: ~U[2026-03-12 12:00:00Z]
      })
      |> Repo.insert!()

    asset
    |> Ecto.Changeset.change(current_video_id: video.id)
    |> Repo.update!()

    embed =
      %Embed{}
      |> Embed.changeset(%{
        space_id: space.id,
        asset_id: asset.id,
        embed_settings_id: settings.id,
        hash: unique_embed_hash(),
        type: :video
      })
      |> Repo.insert!()
      |> Repo.preload([:space, :settings, asset: [:current_video]])

    assert {:ok, _manifest} = ManifestPublisher.publish(embed)

    assert_receive {:purged, space_hash, "eu_2", paths}
    assert space_hash == space.hash
    assert "#{embed.hash}/manifest.json" in paths
    assert "#{embed.hash}/" in paths
  end

  test "serializes concurrent manifest publications for the same embed" do
    start_supervised!(SerializedStorageAdapter)
    Application.put_env(:mave_core, :flow_storage_adapter, SerializedStorageAdapter)

    embed = manifest_embed_fixture()

    tasks =
      for _index <- 1..4 do
        Task.async(fn ->
          receive do
            :publish -> ManifestPublisher.publish(embed, %{"status" => "processing"})
          end
        end)
      end

    Enum.each(tasks, &send(&1.pid, :publish))

    assert Enum.all?(Task.await_many(tasks), &match?({:ok, _manifest}, &1))
    assert %{active: 0, max_active: 1, puts: puts} = SerializedStorageAdapter.stats()
    assert puts >= 4
  end

  defp manifest_embed_fixture do
    space = space_fixture()

    settings =
      %EmbedSettings{}
      |> EmbedSettings.changeset(%{space_id: space.id})
      |> Repo.insert!()

    asset =
      %Asset{}
      |> Asset.changeset(%{space_id: space.id, name: "Concurrent manifest"})
      |> Repo.insert!()

    video =
      %Video{}
      |> Video.changeset(%{
        asset_id: asset.id,
        status: "uploading",
        file_name: "concurrent.mp4"
      })
      |> Repo.insert!()

    asset
    |> Ecto.Changeset.change(current_video_id: video.id)
    |> Repo.update!()

    %Embed{}
    |> Embed.changeset(%{
      space_id: space.id,
      asset_id: asset.id,
      embed_settings_id: settings.id,
      hash: unique_embed_hash(),
      type: :video
    })
    |> Repo.insert!()
    |> Repo.preload([:space, :settings, asset: [:current_video]])
  end

  test "preserves measured waveform data across settings publications" do
    embed = manifest_embed_fixture()
    waveform = %{"version" => 1, "duration" => 12.0, "peaks" => [0.0, 0.5, 1.0]}
    assert {:ok, published} = ManifestPublisher.publish(embed, %{"waveform" => waveform})
    assert published["waveform"] == waveform
    assert {:ok, republished} = ManifestPublisher.publish(embed)
    assert republished["waveform"] == waveform
  end

  defp space_fixture do
    email = "manifest-publisher-#{System.unique_integer([:positive])}@example.com"
    {:ok, user} = Accounts.create_user(email)
    user.current_space_membership.space
  end

  defp unique_embed_hash do
    10
    |> :crypto.strong_rand_bytes()
    |> Base.url_encode64(padding: false)
    |> binary_part(0, 10)
  end

  defp rendition_row(video_id, rendition_key, type, codec, container, size, file_size, now) do
    %{
      id: MaveCore.LegacyShortUUID.dump!(Ecto.UUID.generate()),
      video_id: MaveCore.LegacyShortUUID.dump!(video_id),
      rendition_key: rendition_key,
      type: type,
      codec: codec,
      container: container,
      size: size,
      progress: 100.0,
      file_size: file_size,
      inserted_at: now,
      updated_at: now
    }
  end
end
