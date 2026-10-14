defmodule MaveCore.Playback.PasswordStorageTest do
  use MaveCoreWeb.ConnCase, async: false

  alias MaveCore.{Accounts, Embeds, Playback}
  alias MaveCore.Media.Storage
  alias MaveCore.Playback.{Minio, Password}

  @moduletag :integration

  setup do
    keys = [:playback_adapter, :playback_storage_adapter, :playback_public_storage_endpoint]
    previous = Map.new(keys, &{&1, Application.get_env(:mave_core, &1)})
    Application.put_env(:mave_core, :playback_adapter, Minio)
    Application.put_env(:mave_core, :playback_storage_adapter, Minio)
    Application.delete_env(:mave_core, :playback_public_storage_endpoint)

    on_exit(fn ->
      for {key, value} <- previous do
        if value,
          do: Application.put_env(:mave_core, key, value),
          else: Application.delete_env(:mave_core, key)
      end
    end)

    {:ok, user} =
      Accounts.create_user("password-storage-#{System.unique_integer([:positive])}@example.com")

    space = user.current_space_membership.space
    bucket = Storage.bucket_for_space(space.hash, space.region)
    assert :ok = Storage.ensure_bucket(bucket, space.region)
    %{space: space, bucket: bucket}
  end

  test "private bucket rejects all media while public player and signed bytes remain available",
       %{space: space, bucket: bucket} do
    {:ok, embed} = Embeds.create_video_embed(space)

    {:ok, embed} =
      Embeds.begin_video_upload(space.hash, embed.hash, %{"title" => "Synthetic test"})

    files = [
      "manifest.json",
      "playlist.m3u8",
      "v1/h264_hd.mp4",
      "v1/h264_hd_hls/playlist.m3u8",
      "v1/h264_hd_hls/segment.ts",
      "v1/subtitle_en.vtt",
      "player.html"
    ]

    for path <- files do
      assert {:ok, _} =
               Storage.put(
                 bucket,
                 embed.hash <> "/" <> path,
                 "synthetic bytes",
                 "application/octet-stream",
                 space.region
               )
    end

    on_exit(fn -> Storage.delete_prefix(bucket, embed.hash, space.region) end)
    assert :ok = Minio.apply_visibility(embed, :public)

    assert {:ok, %{status: 200}} =
             Req.get(Minio.object_url(bucket, embed.hash <> "/v1/h264_hd.mp4"))

    assert {:ok, _} = Password.update(embed, %{password: "synthetic-viewer-value"})
    embed = Playback.get_embed(space.hash <> embed.hash)
    assert embed.playback_status == :private

    for path <- files -- ["player.html"] do
      assert {:ok, %{status: status}} =
               Req.get(Minio.object_url(bucket, embed.hash <> "/" <> path))

      assert status in [401, 403, 404]
    end

    assert {:ok, %{status: 200}} = Req.get(Minio.object_url(bucket, embed.hash <> "/player.html"))
    {:ok, session} = Password.issue(embed, "synthetic-viewer-value")

    conn =
      get(build_conn(), "/api/v1/playback/media/#{space.hash}#{embed.hash}/v1/h264_hd.mp4", %{
        token: session.token
      })

    assert conn.status == 302
    url = redirected_to(conn)
    assert URI.parse(url).host in ["localhost", "127.0.0.1"]
    assert {:ok, %{status: 200, body: "synthetic bytes"}} = Req.get(url)

    # Replacements use the same protected prefix, including newly written objects.
    assert {:ok, _} =
             Storage.put(
               bucket,
               embed.hash <> "/v2/h264_hd.mp4",
               "replacement bytes",
               "video/mp4",
               space.region
             )

    assert :ok = Minio.sync_space_domain_cors(space)

    assert {:ok, %{status: status}} =
             Req.get(Minio.object_url(bucket, embed.hash <> "/v2/h264_hd.mp4"))

    assert status in [401, 403, 404]
    {:ok, _} = Password.update(embed, %{password: nil})

    assert get(
             build_conn(),
             "/api/v1/playback/media/#{space.hash}#{embed.hash}/v1/h264_hd.mp4",
             %{token: session.token}
           ).status == 401

    # Revocation cannot retract a previously issued signed storage URL.
    assert {:ok, %{status: 200}} = Req.get(url)
  end
end
