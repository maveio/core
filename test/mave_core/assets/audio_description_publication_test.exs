defmodule MaveCore.Assets.AudioDescriptionPublicationTest do
  use MaveCore.DataCase, async: false

  alias MaveCore.Assets
  alias MaveCore.Assets.{Asset, AudioDescription, AudioTrack, Rendition, Video}
  alias MaveCore.Embeds.{Embed, ManifestPublisher}
  alias MaveCore.Spaces.Space
  alias MaveCore.TestSupport.FlowStorageAdapterStub, as: Storage

  setup do
    previous = Application.get_env(:mave_core, :flow_storage_adapter)
    previous_purger = Application.get_env(:mave_core, :cdn_cache_purger)
    Application.put_env(:mave_core, :flow_storage_adapter, Storage)
    Application.put_env(:mave_core, :cdn_cache_purger, fn _, _, _ -> :ok end)
    Storage.reset!()

    on_exit(fn ->
      restore_env(:flow_storage_adapter, previous)
      restore_env(:cdn_cache_purger, previous_purger)
      Storage.reset!()
    end)

    :ok
  end

  test "the rebuilt HLS master lists audio descriptions next to the original audio" do
    embed = embed_fixture()
    description(embed, "en")
    description(embed, "nl")

    assert :ok = Assets.refresh_hls_master_playlist(embed)
    {:ok, body} = Storage.get("space-abcde", "abcdefghij/playlist.m3u8", "eu")

    assert body =~ ~s(NAME="Original",LANGUAGE="en",DEFAULT=YES,AUTOSELECT=YES,CHANNELS="2")

    for {language, name} <- [{"en", "English"}, {"nl", "Dutch"}] do
      assert body =~
               ~s|NAME="#{name} (audio description)",LANGUAGE="#{language}",DEFAULT=NO,AUTOSELECT=YES,| <>
                 ~s|CHARACTERISTICS="public.accessibility.describes-video",CHANNELS="2",| <>
                 ~s|URI="audio_description_#{language}_hls/playlist.m3u8"|
    end
  end

  test "the manifest has audio descriptions only when there are some" do
    embed = embed_fixture()

    assert {:ok, manifest} = ManifestPublisher.current(embed)
    refute Map.has_key?(manifest, "audio_descriptions")
    assert [%{"filename" => "audio.mp3"}] = manifest["audio_tracks"]

    description(embed, "nl")
    assert {:ok, manifest} = ManifestPublisher.current(embed)

    assert [
             %{
               "language" => "nl",
               "label" => "Dutch (audio description)",
               "audio" => %{
                 "path" => mp3,
                 "hls_playlist" => "audio_description_nl_hls/playlist.m3u8"
               },
               "vtt" => %{"path" => vtt}
             }
           ] = manifest["audio_descriptions"]

    assert String.ends_with?(mp3, "/abcdefghij/audio_description_nl.mp3")
    assert String.ends_with?(vtt, "/abcdefghij/descriptions_nl.vtt")
    assert [%{"filename" => "audio.mp3"}] = manifest["audio_tracks"]
  end

  defp embed_fixture do
    space = Repo.insert!(%Space{hash: "abcde", region: "eu"})
    asset = Repo.insert!(%Asset{space_id: space.id})
    video = Repo.insert!(%Video{asset_id: asset.id, duration: 10.0})
    asset |> Ecto.Changeset.change(current_video_id: video.id) |> Repo.update!()

    Repo.insert!(%Rendition{
      video_id: video.id,
      rendition_key: "abcdefghij/h264_hd_hls/playlist.m3u8",
      type: :video,
      codec: :h264,
      container: :hls,
      size: :hd,
      progress: 100.0
    })

    Repo.insert!(%AudioTrack{
      video_id: video.id,
      filename: "audio.mp3",
      label: "Original",
      language: "en",
      codec: "mp3",
      default: true
    })

    Repo.insert!(%Embed{space_id: space.id, asset_id: asset.id, hash: "abcdefghij"})
    |> Repo.preload([:space, asset: [:current_video]])
  end

  defp description(embed, language) do
    %AudioDescription{}
    |> AudioDescription.changeset(%{
      video_id: embed.asset.current_video.id,
      language: language,
      audio_filename: "audio_description_#{language}.mp3",
      audio_file_size: 1000,
      vtt_filename: "descriptions_#{language}.vtt",
      vtt_file_size: 100,
      cue_count: 2,
      ducked_cue_count: 1
    })
    |> Repo.insert!()
  end

  defp restore_env(key, nil), do: Application.delete_env(:mave_core, key)
  defp restore_env(key, value), do: Application.put_env(:mave_core, key, value)
end
