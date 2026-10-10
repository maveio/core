defmodule MaveCoreWeb.Api.PlaybackControllerTest do
  use MaveCoreWeb.ConnCase, async: false

  alias MaveCore.{Accounts, Embeds, PublicApi, Repo, Spaces}
  alias MaveCore.Assets.{AudioTrack, Subtitle}
  alias MaveCore.Embeds.SettingsSerializer
  alias MaveCore.Playback.Media
  alias MaveCore.Workers.PlaybackVisibilityWorker

  def available?(_space), do: Process.get(:playback_available, true)
  def token_endpoint, do: MaveCoreWeb.Endpoint

  def apply_visibility(embed, visibility) do
    send(self(), {:storage_visibility, embed.id, visibility})
    Process.get(:playback_storage_result, :ok)
  end

  def object_info(_bucket, _path, _region), do: {:ok, %{size_bytes: 100}}

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
    %{space: space, key: key, read_key: read_key}
  end

  test "private creation protects storage before returning, and default creation stays public",
       context do
    conn = api(context.key) |> post("/api/v1/videos", %{name: "Private", visibility: "private"})

    assert %{
             "id" => id,
             "visibility" => "private",
             "visibility_status" => "private",
             "sources" => []
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

  test "visibility stays protecting until storage synchronization succeeds", context do
    {:ok, embed} = Embeds.create_video_embed(context.space)
    Process.put(:playback_storage_result, {:error, :cache_purge_timeout})

    Oban.Testing.with_testing_mode(:manual, fn ->
      conn = api(context.key) |> put("/api/v1/videos/#{embed.hash}", %{visibility: "private"})
      assert %{"visibility_status" => "protecting"} = json_response(conn, 200)
    end)

    job = %Oban.Job{args: %{"embed_id" => embed.id}}

    for reason <- [:cache_purge_timeout, :cache_purge_failed, :cache_pipeline_missing] do
      Process.put(:playback_storage_result, {:error, reason})

      assert {:error, :playback_storage_sync_failed} =
               PlaybackVisibilityWorker.perform(job)

      assert PublicApi.get_embed(context.space, embed.hash).playback_status == :protecting
    end

    Process.put(:playback_storage_result, :ok)
    assert :ok = PlaybackVisibilityWorker.perform(job)
    assert PublicApi.get_embed(context.space, embed.hash).playback_status == :private
  end

  test "API sources play with the original JWT, including child playlists and files", context do
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
    assert %{"sources" => sources} = json_response(conn, 200)
    assert length(sources) == 2
    hls = Enum.find(sources, &(&1["type"] == "application/x-mpegURL"))
    path = URI.parse(hls["src"]).path
    assert path == "/api/v1/playback/media/#{context.space.hash}#{embed.hash}/playlist.m3u8"

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

    mp4 = Enum.find(sources, &(&1["type"] == "video/mp4"))

    conn =
      build_conn()
      |> put_req_header("authorization", "Bearer " <> token)
      |> get(URI.parse(mp4["src"]).path)

    assert conn.status == 302
    assert hd(get_resp_header(conn, "location")) =~ "v1/h264_hd.mp4"

    {:ok, other} = Embeds.create_video_embed(context.space)
    wrong = sign(context.read_key, %{"sub" => context.space.hash <> other.hash})
    assert get(build_conn(), path <> "?" <> URI.encode_query(%{token: wrong})).status == 401
    {:ok, _} = Spaces.delete_key(context.read_key)
    assert get(build_conn(), path <> "?" <> URI.encode_query(%{token: token})).status == 401
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
