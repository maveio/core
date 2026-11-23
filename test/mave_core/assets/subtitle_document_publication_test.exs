defmodule MaveCore.Assets.SubtitleDocumentPublicationTest do
  use MaveCore.DataCase, async: false

  alias MaveCore.Assets
  alias MaveCore.Assets.{Asset, Subtitle, SubtitleDocument, Video}
  alias MaveCore.Embeds.Embed
  alias MaveCore.Spaces.Space
  alias MaveCore.TestSupport.FlowStorageAdapterStub, as: Storage

  @vtt "WEBVTT\n\n00:00:01.000 --> 00:00:03.000\nHello there\n"

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
      restore_env(:flow_storage_adapter, previous)
      restore_env(:cdn_cache_purger, previous_purger)
      Storage.reset!()
    end)

    :ok
  end

  defp restore_env(key, nil), do: Application.delete_env(:mave_core, key)
  defp restore_env(key, value), do: Application.put_env(:mave_core, key, value)

  test "reads the stored subtitle file as a document" do
    embed = embed_fixture()
    subtitle = subtitle_fixture(embed, "en", @vtt)

    assert {:ok, %SubtitleDocument{cues: [cue]}} = Assets.read_subtitle_document(embed, subtitle)
    assert %{start: 1.0, end: 3.0, text: "Hello there"} = cue
  end

  test "publishing replaces the stored file and clears the cached copy" do
    embed = embed_fixture()
    subtitle = subtitle_fixture(embed, "en", @vtt)
    {:ok, document} = Assets.read_subtitle_document(embed, subtitle)

    document =
      document
      |> SubtitleDocument.put_text("c1", "Hello & welcome")
      |> SubtitleDocument.put_timing("c1", 1.5, 4.0)

    assert {:ok, %Subtitle{} = published} =
             Assets.publish_subtitle_document(embed, subtitle, document)

    assert published.id == subtitle.id
    assert published.path == "#{embed.hash}/subtitle_en.vtt"

    assert {:ok, "WEBVTT\n\n00:00:01.500 --> 00:00:04.000\nHello &amp; welcome\n"} =
             Storage.get("space-#{embed.space.hash}", published.path, "eu")

    assert_received {:purged, keys}
    assert "#{embed.hash}/" in keys

    assert {:ok, %SubtitleDocument{cues: [%{text: "Hello & welcome"}]}} =
             Assets.read_subtitle_document(embed, published)
  end

  test "a document without text is not published" do
    embed = embed_fixture()
    subtitle = subtitle_fixture(embed, "en", @vtt)
    {:ok, document} = Assets.read_subtitle_document(embed, subtitle)

    assert {:error, :empty_subtitle} =
             Assets.publish_subtitle_document(
               embed,
               subtitle,
               SubtitleDocument.put_text(document, "c1", " ")
             )

    assert {:ok, @vtt} = Storage.get("space-#{embed.space.hash}", subtitle.path, "eu")
  end

  test "a subtitle of another video is refused" do
    embed = embed_fixture()
    other = embed_fixture()
    subtitle = subtitle_fixture(other, "en", @vtt)
    {:ok, document} = SubtitleDocument.parse(@vtt)

    assert {:error, _reason} = Assets.read_subtitle_document(embed, subtitle)
    assert {:error, _reason} = Assets.publish_subtitle_document(embed, subtitle, document)
  end

  test "a missing or unreadable file is reported" do
    embed = embed_fixture()
    missing = subtitle_fixture(embed, "en", nil)
    broken = subtitle_fixture(embed, "nl", "not a subtitle file")

    assert {:error, :subtitle_not_found} = Assets.read_subtitle_document(embed, missing)
    assert {:error, :invalid_webvtt} = Assets.read_subtitle_document(embed, broken)
  end

  defp embed_fixture do
    hash = unique_hash()
    space = Repo.insert!(%Space{hash: String.slice(hash, 0, 5), region: "eu"})
    asset = Repo.insert!(%Asset{space_id: space.id})
    video = Repo.insert!(%Video{asset_id: asset.id, duration: 10.0})
    asset |> Ecto.Changeset.change(current_video_id: video.id) |> Repo.update!()

    Repo.insert!(%Embed{space_id: space.id, asset_id: asset.id, hash: hash})
    |> Repo.preload([:space, asset: [:current_video]])
  end

  defp subtitle_fixture(embed, language, body) do
    path = "#{embed.hash}/subtitle_#{language}.vtt"
    if body, do: Storage.put_public("space-#{embed.space.hash}", path, body, "text/vtt", "eu")

    Repo.insert!(%Subtitle{
      video_id: embed.asset.current_video.id,
      language: language,
      path: path
    })
  end

  defp unique_hash do
    System.unique_integer([:positive])
    |> Integer.to_string(36)
    |> String.pad_leading(10, "0")
    |> String.slice(-10, 10)
    |> String.reverse()
  end
end
