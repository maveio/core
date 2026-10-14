defmodule MaveCoreWeb.Api.PlaybackControllerTest do
  use MaveCoreWeb.ConnCase, async: false

  alias MaveCore.{Accounts, Embeds, PublicApi, Repo, Spaces}
  alias MaveCore.Assets.{AudioTrack, Subtitle}
  alias MaveCore.Embeds.SettingsSerializer
  alias MaveCore.Playback.Media
  alias MaveCore.Playback.Password
  alias MaveCore.Workers.PlaybackVisibilityWorker

  def available?(_space), do: Process.get(:playback_available, true)
  def token_endpoint, do: MaveCoreWeb.Endpoint

  def apply_visibility(embed, visibility) do
    send(self(), {:storage_visibility, embed.id, visibility})
    Process.get(:playback_storage_result, :ok)
  end

  def object_info(_bucket, _path, _region), do: {:ok, %{size_bytes: 100}}

  def put_public(_bucket, _path, _body, _content_type, _region), do: {:ok, %{}}

  def get(_bucket, path, _region) do
    cond do
      String.ends_with?(path, ".json") ->
        {:error, :not_found}

      String.ends_with?(path, "/storyboard.vtt") ->
        {:ok,
         Process.get(
           :storyboard_body,
           "WEBVTT\n\n00:00.000 --> 00:05.000\nstoryboard.jpg#xywh=0,0,320,180\n"
         )}

      String.ends_with?(path, "/h264_hd_hls/playlist.m3u8") ->
        {:ok, "#EXTM3U\nsegment_000.ts\n#EXT-X-ENDLIST\n"}

      true ->
        {:ok, "#EXTM3U\nh264_hd_hls/playlist.m3u8\n"}
    end
  end

  def presigned_get_url(bucket, path, _region, opts),
    do: {:ok, "https://storage.example.test/#{bucket}/#{path}?expires=#{opts[:expires]}"}

  setup do
    previous_origin = Application.get_env(:mave_core, :playback_origin)
    Application.delete_env(:mave_core, :playback_origin)

    on_exit(fn ->
      if previous_origin,
        do: Application.put_env(:mave_core, :playback_origin, previous_origin),
        else: Application.delete_env(:mave_core, :playback_origin)
    end)

    previous =
      for key <- [:playback_adapter, :playback_storage_adapter, :flow_storage_adapter],
          into: %{},
          do: {key, Application.get_env(:mave_core, key)}

    Enum.each(Map.keys(previous), &Application.put_env(:mave_core, &1, __MODULE__))

    on_exit(fn ->
      Enum.each(previous, fn {key, value} ->
        if value,
          do: Application.put_env(:mave_core, key, value),
          else: Application.delete_env(:mave_core, key)
      end)
    end)

    {:ok, user} =
      Accounts.create_user("playback-api-#{System.unique_integer([:positive])}@example.com")

    space = user.current_space_membership.space
    {:ok, key} = Spaces.create_key(space)
    {:ok, read_key} = Spaces.create_key(space, %{access_level: "read_only"})
    unique = System.unique_integer([:positive])

    %{
      space: space,
      key: key,
      read_key: read_key,
      password_ip: {10, div(unique, 65_536), rem(div(unique, 256), 256), rem(unique, 256)}
    }
  end

  test "private creation protects storage before returning, and default creation stays public",
       context do
    conn = api(context.key) |> post("/api/v1/videos", %{name: "Private", visibility: "private"})

    assert %{
             "id" => id,
             "visibility" => "private"
           } = json_response(conn, 200)

    embed = PublicApi.get_embed(context.space, id)
    assert_receive {:storage_visibility, embed_id, :private}
    assert embed_id == embed.id
    assert is_nil(embed.asset.current_video_id)

    conn = api(context.key) |> post("/api/v1/videos", %{name: "Default"})
    assert %{"visibility" => "public"} = json_response(conn, 200)
  end

  test "failed or unavailable private protection and invalid visibility leave no video behind",
       context do
    Process.put(:playback_storage_result, {:error, :storage_unavailable})
    conn = api(context.key) |> post("/api/v1/videos", %{visibility: "private"})
    assert conn.status == 400
    assert PublicApi.count_videos(context.space, []) == 0

    Process.put(:playback_available, false)
    conn = api(context.key) |> post("/api/v1/videos", %{visibility: "private"})
    assert conn.status == 400
    conn = api(context.key) |> post("/api/v1/videos", %{visibility: "unknown"})
    assert conn.status == 400
    assert PublicApi.count_videos(context.space, []) == 0
  end

  test "visibility updates require write access", context do
    {:ok, embed} = Embeds.create_video_embed(context.space)
    conn = api(context.read_key) |> put("/api/v1/videos/#{embed.hash}", %{visibility: "private"})
    assert conn.status == 403
    assert PublicApi.get_embed(context.space, embed.hash).playback_visibility == :public

    conn = api(context.key) |> put("/api/v1/videos/#{embed.hash}", %{visibility: "private"})
    assert %{"visibility" => "private"} = json_response(conn, 200)
    conn = api(context.key) |> put("/api/v1/videos/#{embed.hash}", %{visibility: "public"})
    assert %{"visibility" => "public"} = json_response(conn, 200)
  end

  test "visibility changes only after storage synchronization succeeds", context do
    {:ok, embed} = Embeds.create_video_embed(context.space)
    path = "/api/v1/videos/#{embed.hash}"
    job = %Oban.Job{args: %{"embed_id" => embed.id}}

    for {previous, target} <- [{"public", "private"}, {"private", "public"}] do
      Oban.Testing.with_testing_mode(:manual, fn ->
        conn = api(context.key) |> put(path, %{visibility: target})
        response = json_response(conn, 202)
        assert response["visibility"] == previous
        refute Map.has_key?(response, "visibility_status")
      end)

      for reason <- [:cache_purge_timeout, :cache_purge_failed, :cache_pipeline_missing] do
        Process.put(:playback_storage_result, {:error, reason})

        assert {:error, :playback_storage_sync_failed} = PlaybackVisibilityWorker.perform(job)
        conn = api(context.read_key) |> get(path)
        assert json_response(conn, 202)["visibility"] == previous
        assert MaveCore.Playback.protected?(PublicApi.get_embed(context.space, embed.hash))
      end

      Process.put(:playback_storage_result, :ok)
      assert :ok = PlaybackVisibilityWorker.perform(job)
      conn = api(context.read_key) |> get(path)
      assert json_response(conn, 200)["visibility"] == target
    end
  end

  test "reversing a pending change retains the last confirmed visibility", context do
    {:ok, embed} = Embeds.create_video_embed(context.space)
    path = "/api/v1/videos/#{embed.hash}"

    Oban.Testing.with_testing_mode(:manual, fn ->
      for target <- ["private", "public"] do
        conn = api(context.key) |> put(path, %{visibility: target})
        assert json_response(conn, 202)["visibility"] == "public"
      end

      conn = api(context.read_key) |> get(path)
      assert json_response(conn, 202)["visibility"] == "public"
    end)

    assert :ok = PlaybackVisibilityWorker.perform(%Oban.Job{args: %{"embed_id" => embed.id}})
    assert_receive {:storage_visibility, _, :public}
    conn = api(context.read_key) |> get(path)
    assert json_response(conn, 200)["visibility"] == "public"
  end

  test "ordinary updates and already confirmed visibility keep HTTP 200", context do
    {:ok, embed} = Embeds.create_video_embed(context.space)
    path = "/api/v1/videos/#{embed.hash}"

    Oban.Testing.with_testing_mode(:manual, fn ->
      conn = api(context.key) |> put(path, %{visibility: "public"})
      assert json_response(conn, 200)["visibility"] == "public"

      conn = api(context.key) |> put(path, %{visibility: "private"})
      assert conn.status == 202
      conn = api(context.key) |> put(path, %{name: "Renamed"})
      assert json_response(conn, 200)["visibility"] == "public"
    end)
  end

  test "media URLs play with the original JWT, including child playlists and files", context do
    {:ok, embed} = Embeds.create_video_embed(context.space, %{visibility: :private})

    {:ok, embed} =
      Embeds.begin_video_upload(context.space.hash, embed.hash, %{"title" => "video.mp4"})

    now = DateTime.utc_now() |> DateTime.truncate(:second)

    for {container, key} <- [
          {"hls", "#{embed.hash}/v1/h264_hd_hls/playlist.m3u8"},
          {"mp4", "#{embed.hash}/v1/h264_hd.mp4"}
        ] do
      Repo.insert_all("renditions", [
        %{
          id: MaveCore.LegacyShortUUID.dump!(Ecto.UUID.generate()),
          video_id: MaveCore.LegacyShortUUID.dump!(embed.asset.current_video_id),
          rendition_key: key,
          type: "video",
          codec: "h264",
          container: container,
          size: "hd",
          progress: 100.0,
          inserted_at: now,
          updated_at: now
        }
      ])
    end

    conn = api(context.read_key) |> get("/api/v1/videos/#{embed.hash}")
    refute Map.has_key?(json_response(conn, 200), "sources")
    base = "/api/v1/playback/media/#{context.space.hash}#{embed.hash}"
    path = base <> "/playlist.m3u8"

    token =
      sign(context.read_key, %{
        "sub" => context.space.hash <> embed.hash,
        "exp" => System.system_time(:second) + 600
      })

    assert get(build_conn(), path).status == 401
    conn = get(build_conn(), path <> "?" <> URI.encode_query(%{token: token}))
    playlist = response(conn, 200)
    child = playlist |> String.split("\n") |> Enum.find(&String.contains?(&1, "h264_hd_hls"))
    assert URI.decode_query(URI.parse(child).query)["token"] == token
    assert response(get(build_conn(), child), 200) =~ "https://storage.example.test/"

    conn =
      build_conn()
      |> put_req_header("authorization", "Bearer " <> token)
      |> get(base <> "/v1/h264_hd.mp4")

    assert conn.status == 302
    assert hd(get_resp_header(conn, "location")) =~ "v1/h264_hd.mp4"

    {:ok, other} = Embeds.create_video_embed(context.space)
    wrong = sign(context.read_key, %{"sub" => context.space.hash <> other.hash})
    assert get(build_conn(), path <> "?" <> URI.encode_query(%{token: wrong})).status == 401
    {:ok, _} = Spaces.delete_key(context.read_key)
    assert get(build_conn(), path <> "?" <> URI.encode_query(%{token: token})).status == 401
  end

  test "video responses do not add a sources field to either format", context do
    {:ok, embed} = Embeds.create_video_embed(context.space)

    for version <- [1, 2], visibility <- [:public, :private] do
      response =
        PublicApi.video_response(context.space, %{
          embed
          | version: version,
            playback_visibility: visibility,
            playback_status: visibility
        })

      refute Map.has_key?(response, :sources)
      refute Map.has_key?(response, :visibility_status)
      assert response.visibility == visibility
      assert Map.has_key?(response, :poster_image)
    end
  end

  test "space, collection and video database IDs constrain JWT scope", context do
    {:ok, folder} = Embeds.create_folder_embed(context.space, %{name: "Folder"})
    {:ok, child} = Embeds.create_video_embed(context.space, %{parent_folder_id: folder.id})
    {:ok, other} = Embeds.create_video_embed(context.space)

    for sub <- [context.space.id, folder.id, child.id] do
      token = sign(context.read_key, %{"sub" => sub})
      assert {:ok, _} = MaveCore.Playback.authorize(token, child)

      if sub != context.space.id,
        do: assert({:error, :unauthorized} == MaveCore.Playback.authorize(token, other))
    end
  end

  test "custom players can preflight bearer authorization" do
    conn =
      build_conn()
      |> put_req_header("origin", "https://player.example.test")
      |> put_req_header("access-control-request-method", "GET")
      |> put_req_header("access-control-request-headers", "authorization")
      |> options("/api/v1/playback/media/aaaaabbbbbccccc/playlist.m3u8")

    assert conn.status == 204
    assert get_resp_header(conn, "access-control-allow-origin") == ["*"]
    assert hd(get_resp_header(conn, "access-control-allow-headers")) =~ "authorization"
  end

  test "space media host serves JWT playlists and keeps management routes closed", context do
    Application.put_env(:mave_core, :playback_origin, "https://signed.example.test")
    {:ok, embed} = Embeds.create_video_embed(context.space, %{visibility: :private})
    token = sign(context.read_key, %{"sub" => context.space.hash <> embed.hash})
    origin = "https://space-#{context.space.hash}.signed.example.test"
    path = "/#{embed.hash}/playlist.m3u8"
    query = URI.encode_query(%{token: token})

    conn = get(build_conn(), origin <> path <> "?" <> query)
    assert conn.status == 200
    assert conn.resp_body =~ "/#{embed.hash}/h264_hd_hls/playlist.m3u8?token="
    refute conn.resp_body =~ "/api/v1/"
    assert get_resp_header(conn, "cache-control") == ["private, no-store"]
    assert get_resp_header(conn, "access-control-allow-origin") == ["*"]
    assert get(build_conn(), origin <> path).status == 401
    assert get(build_conn(), origin <> "/api/v1/videos").status == 404
    assert get(build_conn(), origin <> "/login").status == 404
    assert post(build_conn(), origin <> path, %{}).status == 404
    assert options(build_conn(), origin <> path).status == 204

    {:ok, other_user} =
      Accounts.create_user("other-host-#{System.unique_integer([:positive])}@example.com")

    other = other_user.current_space_membership.space
    other_origin = "https://space-#{other.hash}.signed.example.test"
    assert get(build_conn(), other_origin <> path <> "?" <> query).status == 401
    # A query-string id cannot override the tenant selected by the hostname.
    assert get(
             build_conn(),
             other_origin <> path <> "?" <> query <> "&id=" <> context.space.hash <> embed.hash
           ).status == 401

    assert get(build_conn(), "https://bad.signed.example.test" <> path <> "?" <> query).status ==
             404

    response = PublicApi.video_response(context.space, embed)
    assert response.poster_image == origin <> "/#{embed.hash}/thumbnail.jpg"

    endpoint =
      SettingsSerializer.component_runtime_config()["cdn"]["playback_endpoint"]

    assert endpoint == "https://space-${this.spaceId}.signed.example.test/${this.embedId}"

    # Existing API links remain valid during rollout and for self-hosted installs.
    assert get(
             build_conn(),
             "/api/v1/playback/media/#{context.space.hash}#{embed.hash}/playlist.m3u8?" <> query
           ).status == 200
  end

  test "storyboards authorize their sprite images and keep crop coordinates", context do
    {:ok, embed} = Embeds.create_video_embed(context.space, %{visibility: :private})

    token =
      sign(context.read_key, %{
        sub: context.space.hash <> embed.hash,
        exp: System.system_time(:second) + 3600
      })

    base = "/api/v1/playback/media/#{context.space.hash}#{embed.hash}"

    for version <- ["", "v2/"] do
      path = base <> "/" <> version <> "storyboard.vtt"
      assert get(build_conn(), path).status == 401
      conn = Phoenix.ConnTest.get(build_conn(), path, %{token: token})
      assert [type] = get_resp_header(conn, "content-type")
      assert type =~ "text/vtt"
      assert conn.resp_body =~ "WEBVTT"
      assert conn.resp_body =~ "00:00.000 --> 00:05.000"
      assert conn.resp_body =~ "/#{embed.hash}/#{version}storyboard.jpg?expires="
      assert conn.resp_body =~ "#xywh=0,0,320,180"
      assert get_resp_header(conn, "cache-control") == ["private, no-store"]
    end

    Process.put(
      :storyboard_body,
      "WEBVTT\n\n00:00.000 --> 00:05.000\n../other/storyboard.jpg#xywh=0,0,320,180\n"
    )

    assert Phoenix.ConnTest.get(build_conn(), base <> "/storyboard.vtt", %{token: token}).status ==
             404
  end

  test "private manifests authorize path-style storage subtitles, audio and posters", context do
    original = Application.get_env(:mave_core, :public_cdn_base_url)
    Application.put_env(:mave_core, :public_cdn_base_url, "http://storage.example.test:9000")

    on_exit(fn ->
      if original,
        do: Application.put_env(:mave_core, :public_cdn_base_url, original),
        else: Application.delete_env(:mave_core, :public_cdn_base_url)
    end)

    {:ok, embed} = Embeds.create_video_embed(context.space, %{visibility: :private})

    {:ok, embed} =
      Embeds.begin_video_upload(context.space.hash, embed.hash, %{"title" => "video.mp4"})

    video_id = embed.asset.current_video_id

    %Subtitle{}
    |> Subtitle.changeset(%{
      video_id: video_id,
      language: "en",
      path: "#{embed.hash}/v1/subtitle_en.vtt"
    })
    |> Repo.insert!()

    %AudioTrack{}
    |> AudioTrack.changeset(%{
      video_id: video_id,
      filename: "audio.mp3",
      default: true
    })
    |> Repo.insert!()

    token = sign(context.read_key, %{sub: context.space.hash <> embed.hash})
    base = "/api/v1/playback/media/#{context.space.hash}#{embed.hash}"
    conn = Phoenix.ConnTest.get(build_conn(), base <> "/manifest.json", %{token: token})
    manifest = json_response(conn, 200)
    assert [%{"path" => subtitle}] = manifest["subtitles"]
    assert [%{"path" => audio}] = manifest["audio_tracks"]

    for {url, filename} <- [{subtitle, "v1/subtitle_en.vtt"}, {audio, "audio.mp3"}] do
      uri = URI.parse(url)
      assert uri.host == "www.example.com"
      assert uri.path == base <> "/" <> filename
      assert URI.decode_query(uri.query)["token"] == token
      assert get(build_conn(), uri.path).status == 401
      conn = get(build_conn(), url)
      assert conn.status == 302
      assert redirected_to(conn) =~ "/#{embed.hash}/#{filename}?expires="
    end

    for filename <- [
          "poster.jpg",
          "thumbnail.jpg",
          "storyboard.jpg",
          "subtitle.json",
          "h264_hd.mp4"
        ] do
      assert get(build_conn(), base <> "/v1/" <> filename).status == 401

      assert Phoenix.ConnTest.get(build_conn(), base <> "/v1/" <> filename, %{token: token}).status ==
               302
    end

    embed = Repo.preload(embed, :space)
    foreign = "http://storage.example.test:9000/space-other/#{embed.hash}/v1/subtitle_en.vtt"
    assert {:error, :invalid_path} = Media.resolve_path(foreign, embed, ".")
  end

  test "password creation protects storage and exposes only a boolean", context do
    conn = api(context.key) |> post("/api/v1/videos", %{password: "synthetic-viewer-value"})

    assert %{"id" => id, "password_protected" => true, "visibility" => "private"} =
             json_response(conn, 200)

    embed = PublicApi.get_embed(context.space, id)
    assert_receive {:storage_visibility, _, :private}
    assert Argon2.verify_pass("synthetic-viewer-value", embed.password_hash)
    refute conn.resp_body =~ "password_hash"
    refute conn.resp_body =~ "synthetic-viewer-value"
    refute inspect(embed) =~ embed.password_hash
    safe = Password.for_dashboard(embed)
    assert is_nil(safe.password_hash)
    assert Password.protected?(safe)

    for prefix <- ["/api/v1", "/v1"] do
      conn = get(build_conn(), "#{prefix}/playback/#{id}/access")
      assert json_response(conn, 200) == %{"password_protected" => true}
      assert get_resp_header(conn, "cache-control") == ["private, no-store"]
    end
  end

  test "password token grants direct-storage playback and revokes on rotation or removal",
       context do
    {:ok, embed} = Embeds.create_video_embed(context.space, %{password: "synthetic-viewer-value"})
    id = context.space.hash <> embed.hash
    base = "/api/v1/playback/media/#{id}"

    conn =
      password_conn(context)
      |> post("/v1/playback/#{id}/password-token", %{password: "synthetic-viewer-value"})

    assert %{"token" => token, "expires_at" => expires_at} = json_response(conn, 200)
    assert_in_delta expires_at, System.system_time(:second) + 14_400, 3
    assert {:ok, ^expires_at} = MaveCore.Playback.authorize(token, embed)
    media = Phoenix.ConnTest.get(build_conn(), base <> "/v1/h264_hd.mp4", %{token: token})
    assert media.status == 302
    assert redirected_to(media) =~ "https://storage.example.test/"
    assert redirected_to(media) =~ "expires=14"

    for path <- [
          "manifest.json",
          "playlist.m3u8",
          "v1/h264_hd.mp4",
          "v1/h264_hd_hls/segment.ts",
          "v1/subtitle_en.vtt"
        ] do
      assert get(build_conn(), base <> "/" <> path).status == 401
    end

    {:ok, other} = Embeds.create_video_embed(context.space)
    assert {:error, :unauthorized} = MaveCore.Playback.authorize(token, other)

    {:ok, rotated} =
      Password.update(embed, %{password: "synthetic-rotated-value"})

    assert {:error, :unauthorized} = MaveCore.Playback.authorize(token, embed)

    {:ok, session} =
      Password.issue(MaveCore.Playback.get_embed(id), "synthetic-rotated-value")

    assert {:ok, _} = MaveCore.Playback.authorize(session.token, rotated)
    {:ok, removed} = Password.update(rotated, %{password: nil})
    assert removed.playback_status == :private
    refute Password.protected?(removed)
    assert {:error, :unauthorized} = MaveCore.Playback.authorize(session.token, rotated)

    assert Phoenix.ConnTest.get(build_conn(), base <> "/playlist.m3u8", %{token: token}).status ==
             401
  end

  test "storage protection must finish before granting a password token", context do
    {:ok, embed} = Embeds.create_video_embed(context.space)
    id = context.space.hash <> embed.hash

    Oban.Testing.with_testing_mode(:manual, fn ->
      conn =
        api(context.key) |> put("/api/v1/videos/#{id}", %{password: "synthetic-viewer-value"})

      assert %{"password_protected" => true, "visibility" => "public"} = json_response(conn, 202)

      conn =
        password_conn(context)
        |> post("/api/v1/playback/#{id}/password-token", %{password: "synthetic-viewer-value"})

      assert json_response(conn, 409) == %{"error" => "protection_pending"}
      Process.put(:playback_storage_result, {:error, :cache_purge_failed})

      assert {:error, _} =
               PlaybackVisibilityWorker.perform(%Oban.Job{args: %{"embed_id" => embed.id}})

      conn =
        password_conn(context)
        |> post("/api/v1/playback/#{id}/password-token", %{password: "synthetic-viewer-value"})

      assert conn.status == 409
    end)

    Process.put(:playback_storage_result, :ok)
    assert :ok = PlaybackVisibilityWorker.perform(%Oban.Job{args: %{"embed_id" => embed.id}})

    conn =
      password_conn(context)
      |> post("/api/v1/playback/#{id}/password-token", %{password: "synthetic-viewer-value"})

    assert conn.status == 200
  end

  test "password updates preserve API write permission and reject public transitions", context do
    {:ok, embed} = Embeds.create_video_embed(context.space, %{password: "synthetic-viewer-value"})
    path = "/api/v1/videos/#{embed.hash}"
    assert put(api(context.read_key), path, %{password: nil}).status == 403
    assert put(api(context.key), path, %{visibility: "public"}).status == 400
    assert put(api(context.key), path, %{visibility: "public", password: nil}).status == 400

    assert {:error, :password_requires_private} =
             MaveCore.Playback.request_visibility(embed, :public)

    conn = put(api(context.key), path, %{name: "Still protected"})
    assert json_response(conn, 200)["password_protected"]

    assert PublicApi.get_embed(context.space, embed.hash).password_revision ==
             embed.password_revision

    conn = put(api(context.key), path, %{password: nil})
    assert %{"password_protected" => false, "visibility" => "private"} = json_response(conn, 200)
    assert put(api(context.key), path, %{visibility: "public"}).status == 200
  end

  test "invalid passwords and unavailable playback cannot mutate a video", context do
    {:ok, embed} = Embeds.create_video_embed(context.space)

    for invalid <- ["", 123, false, %{}, String.duplicate("a", 1025)] do
      assert put(api(context.key), "/api/v1/videos/#{embed.hash}", %{password: invalid}).status ==
               400
    end

    Process.put(:playback_available, false)

    assert put(api(context.key), "/api/v1/videos/#{embed.hash}", %{
             password: "synthetic-viewer-value"
           }).status == 400

    refute PublicApi.get_embed(context.space, embed.hash)
           |> Password.protected?()

    assert post(api(context.key), "/api/v1/videos", %{password: "synthetic-viewer-value"}).status ==
             400
  end

  test "password requests have bounded attempts and do not trust forwarded IPs", context do
    {:ok, embed} = Embeds.create_video_embed(context.space, %{password: "synthetic-viewer-value"})
    path = "/api/v1/playback/#{context.space.hash}#{embed.hash}/password-token"

    for attempt <- 1..5 do
      conn =
        password_conn(context)
        |> put_req_header("x-forwarded-for", "192.0.2.#{attempt}")
        |> post(path, %{password: "synthetic-wrong-value"})

      assert json_response(conn, 401) == %{"error" => "invalid_password"}
    end

    # Canonicalizing IDs prevents bypass by switching to a UUID alias.
    conn =
      password_conn(context)
      |> post("/v1/playback/#{embed.id}/password-token", %{password: "synthetic-viewer-value"})

    assert json_response(conn, 429) == %{"error" => "rate_limited"}
    assert [_] = get_resp_header(conn, "retry-after")
  end

  test "the IP limit applies across different videos and malformed identifiers", context do
    for _video <- 1..6 do
      {:ok, embed} = Embeds.create_video_embed(context.space)

      for _attempt <- 1..5 do
        conn =
          post(password_conn(context), "/api/v1/playback/#{embed.id}/password-token", %{
            password: "synthetic-wrong-value"
          })

        assert conn.status == 401
      end
    end

    conn =
      post(password_conn(context), "/api/v1/playback/#{Ecto.UUID.generate()}/password-token", %{
        password: "synthetic-wrong-value"
      })

    assert json_response(conn, 429) == %{"error" => "rate_limited"}
  end

  test "a newly unavailable space refuses password issuance", context do
    {:ok, embed} = Embeds.create_video_embed(context.space, %{password: "synthetic-viewer-value"})
    Process.put(:playback_available, false)

    conn =
      post(
        password_conn(context),
        "/api/v1/playback/#{context.space.hash}#{embed.hash}/password-token",
        %{password: "synthetic-viewer-value"}
      )

    assert json_response(conn, 503) == %{"error" => "playback_unavailable"}
  end

  test "password tokens have a distinct purpose and reject expired claims", context do
    {:ok, embed} = Embeds.create_video_embed(context.space, %{password: "synthetic-viewer-value"})

    claims = %{
      embed_id: embed.id,
      space_id: embed.space_id,
      revision: embed.password_revision,
      expires_at: System.system_time(:second) - 1
    }

    token = Phoenix.Token.sign(MaveCoreWeb.Endpoint, "password-playback-v1", claims)
    assert {:error, :unauthorized} = MaveCore.Playback.authorize(token, embed)

    wrong_purpose =
      Phoenix.Token.sign(MaveCoreWeb.Endpoint, "password-playback-other", %{
        claims
        | expires_at: System.system_time(:second) + 600
      })

    assert {:error, :unauthorized} = MaveCore.Playback.authorize(wrong_purpose, embed)

    assert {:ok, _} =
             MaveCore.Playback.authorize(MaveCore.Playback.dashboard_session(embed).token, embed)
  end

  test "missing and deleted embeds do not disclose media metadata", context do
    {:ok, embed} = Embeds.create_video_embed(context.space)
    id = context.space.hash <> embed.hash

    assert json_response(get(build_conn(), "/api/v1/playback/#{id}/access"), 200) == %{
             "password_protected" => false
           }

    conn =
      post(password_conn(context), "/api/v1/playback/#{id}/password-token", %{
        password: "synthetic-wrong-value"
      })

    assert json_response(conn, 401) == %{"error" => "invalid_password"}
    {:ok, _} = Embeds.delete_embed(embed)

    assert json_response(get(build_conn(), "/api/v1/playback/#{id}/access"), 404) == %{
             "error" => "not_found"
           }
  end

  test "password endpoint permits JSON CORS preflight" do
    conn =
      build_conn()
      |> put_req_header("origin", "https://player.example.test")
      |> put_req_header("access-control-request-method", "POST")
      |> put_req_header("access-control-request-headers", "content-type")
      |> options("/api/v1/playback/aaaaabbbbbccccc/password-token")

    assert conn.status == 204
    assert get_resp_header(conn, "access-control-allow-origin") == ["*"]
  end

  defp password_conn(context), do: %{build_conn() | remote_ip: context.password_ip}

  defp api(key),
    do:
      build_conn()
      |> put_req_header("authorization", "Bearer " <> Spaces.display_api_key(key.key, key.secret))

  defp sign(key, claims) do
    encode = fn value -> value |> Jason.encode!() |> Base.url_encode64(padding: false) end
    input = encode.(%{alg: "HS256", typ: "JWT"}) <> "." <> encode.(claims)
    signature = :crypto.mac(:hmac, :sha256, Spaces.display_api_key(key.key, key.secret), input)
    input <> "." <> Base.url_encode64(signature, padding: false)
  end
end
