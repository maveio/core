defmodule MaveCore.Assets.HlsRefreshTest do
  use MaveCore.DataCase, async: false

  alias MaveCore.Assets
  alias MaveCore.Assets.{Asset, AudioTrack, Rendition, Subtitle, Video}
  alias MaveCore.Embeds.Embed
  alias MaveCore.Spaces.Space
  alias MaveCore.TestSupport.FlowStorageAdapterStub, as: Storage

  defmodule UnavailableStorage do
    def get(_, _, _), do: {:error, :timeout}
  end

  setup do
    previous = Application.get_env(:mave_core, :flow_storage_adapter)
    previous_purger = Application.get_env(:mave_core, :cdn_cache_purger)
    Application.put_env(:mave_core, :flow_storage_adapter, Storage)
    owner = self()

    Application.put_env(:mave_core, :cdn_cache_purger, fn _, _, keys ->
      send(owner, {:purged, keys})
      :ok
    end)

    Storage.reset!()

    on_exit(fn ->
      Application.put_env(:mave_core, :flow_storage_adapter, previous)
      Application.put_env(:mave_core, :cdn_cache_purger, previous_purger)
      Storage.reset!()
    end)

    :ok
  end

  test "opaque rendition IDs resolve to stored HLS paths and absent external audio is omitted" do
    embed = embed_fixture()
    legacy_rendition(embed)
    audio_track(embed, "audio.mp3")

    assert :ok = Assets.refresh_hls_master_playlist(embed)
    body = master(embed)
    assert body =~ "h264_hd_hls/playlist.m3u8"
    refute body =~ String.duplicate("a", 32)
    refute body =~ "TYPE=AUDIO"
    refute body =~ "AUDIO=\"audio\""
    assert_received {:purged, ["abcdefghij/playlist.m3u8"]}
  end

  test "legacy replacement versions retain their version prefix and real alternate audio" do
    embed = embed_fixture()
    old = embed.asset.current_video
    earlier = DateTime.add(old.inserted_at, -60, :second)
    Repo.insert!(%Video{asset_id: old.asset_id, inserted_at: earlier})
    legacy_rendition(embed)
    audio_track(embed, "alternate.mp3")
    put(embed, "v1/alternate_hls/playlist.m3u8", "#EXTM3U\n")

    assert :ok = Assets.refresh_hls_master_playlist(embed)
    body = master(embed, "v1/")
    assert body =~ "h264_hd_hls/playlist.m3u8"
    assert body =~ ~s(URI="alternate_hls/playlist.m3u8")
    refute body =~ "abcdefghij/v1/h264"
  end

  test "modern custom rendition paths are preserved" do
    embed = embed_fixture()
    rendition(embed, "#{embed.hash}/custom/video.m3u8")

    assert :ok = Assets.refresh_hls_master_playlist(embed)
    assert master(embed) =~ "custom/video.m3u8"
  end

  test "opaque subtitle IDs resolve to the subtitle file when rebuilding its playlist" do
    embed = embed_fixture()
    legacy_rendition(embed)

    Repo.insert!(%Subtitle{
      video_id: embed.asset.current_video.id,
      language: "fr",
      path: String.duplicate("b", 32)
    })

    assert :ok = Assets.refresh_hls_master_playlist(embed)

    assert {:ok, body} =
             Storage.get("space-abcde", "#{embed.hash}/subtitle_fr_hls/playlist.m3u8", "eu")

    assert body =~ "../subtitle_fr.vtt"
    refute body =~ String.duplicate("b", 32)
  end

  test "storage failures do not silently remove audio or overwrite the master" do
    embed = embed_fixture()
    legacy_rendition(embed)
    audio_track(embed, "audio.mp3")
    put(embed, "playlist.m3u8", "original")
    Application.put_env(:mave_core, :flow_storage_adapter, UnavailableStorage)

    assert {:error, {:audio_playlist_unavailable, :timeout}} =
             Assets.refresh_hls_master_playlist(embed)

    assert master(embed) == "original"
  end

  defp embed_fixture do
    space = Repo.insert!(%Space{hash: "abcde", region: "eu"})
    asset = Repo.insert!(%Asset{space_id: space.id})
    video = Repo.insert!(%Video{asset_id: asset.id, duration: 10.0})
    asset |> Ecto.Changeset.change(current_video_id: video.id) |> Repo.update!()

    Repo.insert!(%Embed{space_id: space.id, asset_id: asset.id, hash: "abcdefghij"})
    |> Repo.preload([:space, asset: [:current_video]])
  end

  defp legacy_rendition(embed), do: rendition(embed, String.duplicate("a", 32))

  defp rendition(embed, key) do
    Repo.insert!(%Rendition{
      video_id: embed.asset.current_video.id,
      rendition_key: key,
      type: :video,
      codec: :h264,
      container: :hls,
      size: :hd,
      progress: 100.0
    })
  end

  defp audio_track(embed, filename) do
    Repo.insert!(%AudioTrack{
      video_id: embed.asset.current_video.id,
      filename: filename,
      codec: "mp3",
      default: true
    })
  end

  defp put(embed, path, body) do
    Storage.put("space-#{embed.space.hash}", "#{embed.hash}/#{path}", body, "text/plain", "eu")
  end

  defp master(embed, prefix \\ "") do
    {:ok, body} =
      Storage.get("space-#{embed.space.hash}", "#{embed.hash}/#{prefix}playlist.m3u8", "eu")

    body
  end
end
