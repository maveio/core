defmodule MaveCore.EncodingBooster.HLSUploadTest do
  use ExUnit.Case, async: false

  alias MaveCore.EncodingBooster.HLSUpload
  alias MaveCore.Media.Storage

  setup do
    old_adapter = Application.get_env(:mave_core, :flow_storage_adapter)
    old_providers = Application.get_env(:mave_core, :storage_providers)

    Application.put_env(:mave_core, :flow_storage_adapter, Storage)

    Application.put_env(:mave_core, :storage_providers, %{
      "qingb" => [
        access_key_id: "destination-key",
        secret_access_key: "destination-secret",
        endpoint: "https://storage.example.test",
        region: "fr-par",
        object_acl: true
      ]
    })

    on_exit(fn ->
      restore_env(:flow_storage_adapter, old_adapter)
      restore_env(:storage_providers, old_providers)
    end)

    :ok
  end

  test "authorizes only exact HLS objects under the signed prefix" do
    assert {:ok, token} = HLSUpload.sign("space-qingb", "embed/h264_hd_hls/", "qingb")

    assert {:ok, uploads} =
             HLSUpload.authorize(token, [
               %{"name" => "init.mp4", "size_bytes" => 4},
               %{"name" => "playlist.m3u8", "size_bytes" => 8},
               %{"name" => "segment_000.m4s", "size_bytes" => 12}
             ])

    assert Enum.map(uploads, & &1["key"]) == [
             "embed/h264_hd_hls/init.mp4",
             "embed/h264_hd_hls/playlist.m3u8",
             "embed/h264_hd_hls/segment_000.m4s"
           ]

    assert Enum.all?(uploads, fn upload ->
             upload["upload"]["url"] =~ "X-Amz-Signature=" and
               upload["upload"]["headers"]["content-length"] ==
                 Integer.to_string(upload["size_bytes"])
           end)

    assert Enum.find(uploads, &(&1["name"] == "init.mp4"))["content_type"] == "video/mp4"
  end

  test "authorizes audio HLS objects with audio content types" do
    assert {:ok, token} =
             HLSUpload.sign("space-qingb", "embed/audio_hls/", "qingb", media_kind: "audio")

    assert {:ok, uploads} =
             HLSUpload.authorize(token, [
               %{"name" => "init.mp4", "size_bytes" => 4},
               %{"name" => "playlist.m3u8", "size_bytes" => 8},
               %{"name" => "segment_000.m4s", "size_bytes" => 12}
             ])

    assert Enum.find(uploads, &(&1["name"] == "init.mp4"))["content_type"] == "audio/mp4"

    assert Enum.find(uploads, &(&1["name"] == "segment_000.m4s"))["content_type"] ==
             "audio/mp4"
  end

  test "rejects traversal and duplicate HLS names" do
    assert {:ok, token} = HLSUpload.sign("space-qingb", "embed/h264_hd_hls/", "qingb")

    assert {:error, :invalid_hls_upload_file} =
             HLSUpload.authorize(token, [%{"name" => "../manifest.json", "size_bytes" => 10}])

    assert {:error, :duplicate_hls_upload_file} =
             HLSUpload.authorize(token, [
               %{"name" => "init.mp4", "size_bytes" => 4},
               %{"name" => "init.mp4", "size_bytes" => 4}
             ])
  end

  defp restore_env(key, nil), do: Application.delete_env(:mave_core, key)
  defp restore_env(key, value), do: Application.put_env(:mave_core, key, value)
end
