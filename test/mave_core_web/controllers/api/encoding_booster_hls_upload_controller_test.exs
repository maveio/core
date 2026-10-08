defmodule MaveCoreWeb.Api.EncodingBoosterHLSUploadControllerTest do
  use MaveCoreWeb.ConnCase, async: false

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

  test "returns scoped upload destinations to a booster with a valid token", %{conn: conn} do
    assert {:ok, token} = HLSUpload.sign("space-qingb", "embed/h264_hd_hls/", "qingb")

    conn =
      conn
      |> put_req_header("authorization", "Bearer #{token}")
      |> post("/internal/encoding-booster/hls-uploads", %{
        "files" => [
          %{"name" => "init.mp4", "size_bytes" => 4},
          %{"name" => "playlist.m3u8", "size_bytes" => 8},
          %{"name" => "segment_000.m4s", "size_bytes" => 12}
        ]
      })

    assert %{"uploads" => uploads} = json_response(conn, 200)
    assert length(uploads) == 3
    assert Enum.at(uploads, 2)["key"] == "embed/h264_hd_hls/segment_000.m4s"
  end

  test "rejects requests without an upload token", %{conn: conn} do
    conn =
      post(conn, "/internal/encoding-booster/hls-uploads", %{
        "files" => [%{"name" => "init.mp4", "size_bytes" => 4}]
      })

    assert %{"error" => "unauthorized"} = json_response(conn, 401)
  end

  defp restore_env(key, nil), do: Application.delete_env(:mave_core, key)
  defp restore_env(key, value), do: Application.put_env(:mave_core, key, value)
end
