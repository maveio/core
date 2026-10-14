defmodule MaveCoreWeb.Api.ScheduledReleaseTest do
  use MaveCoreWeb.ConnCase, async: false

  import Ecto.Query

  alias MaveCore.{Accounts, Embeds, Playback, PublicApi, Repo, Spaces}
  alias MaveCore.Embeds.{Embed, Release}
  alias MaveCore.Workers.ReleaseWorker

  def available?(_space), do: Process.get(:playback_available, true)
  def token_endpoint, do: MaveCoreWeb.Endpoint

  def apply_visibility(embed, visibility) do
    send(self(), {:storage_visibility, embed.id, visibility})
    :ok
  end

  def object_info(_bucket, _path, _region), do: {:ok, %{size_bytes: 100}}
  def put_public(_bucket, _path, _body, _content_type, _region), do: {:ok, %{}}

  def get(_bucket, path, _region) do
    if String.ends_with?(path, ".json"),
      do: {:error, :not_found},
      else: {:ok, "#EXTM3U\nh264_hd_hls/playlist.m3u8\n"}
  end

  def presigned_get_url(bucket, path, _region, _opts),
    do: {:ok, "https://storage.example.test/#{bucket}/#{path}"}

  setup do
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
      Accounts.create_user("release-api-#{System.unique_integer([:positive])}@example.com")

    space = user.current_space_membership.space
    {:ok, key} = Spaces.create_key(space)
    {:ok, read_key} = Spaces.create_key(space, %{access_level: "read_only"})
    {:ok, embed} = Embeds.create_video_embed(space)
    {:ok, embed} = Embeds.begin_video_upload(space.hash, embed.hash, %{"title" => "launch.mp4"})

    %{
      space: space,
      key: key,
      read_key: read_key,
      embed: embed,
      public_id: space.hash <> embed.hash
    }
  end

  test "a scheduled video is private in storage and serves only a countdown manifest", context do
    release_at = System.system_time(:second) + 3600

    conn =
      api(context.key) |> put("/api/v1/videos/#{context.embed.hash}", %{release_at: release_at})

    assert %{"release_at" => ^release_at, "visibility" => "private"} = json_response(conn, 200)
    assert_receive {:storage_visibility, embed_id, :private}
    assert embed_id == context.embed.id

    conn = get(build_conn(), "/api/v1/#{context.public_id}")
    manifest = json_response(conn, 200)
    assert get_resp_header(conn, "cache-control") == ["public, max-age=5"]
    assert manifest["release_at"] == release_at
    assert is_integer(manifest["server_time"])
    assert manifest["name"] == "launch"

    assert %{"status" => "scheduled", "ready" => false, "renditions" => [], "src" => nil} =
             manifest["video"]

    assert manifest["subtitles"] == [] and manifest["audio_tracks"] == []
    assert manifest["poster"]["image_src"] == nil
    assert manifest["settings"]["poster"] == nil
  end

  test "customer JWTs cannot reach media before release; dashboard previews can", context do
    {:ok, _embed} = Release.schedule(context.embed, in_seconds(3600))
    embed = Repo.get!(Embed, context.embed.id)
    base = "/api/v1/playback/media/#{context.public_id}"
    token = sign(context.read_key, %{"sub" => context.public_id})

    assert {:error, :unreleased} = Playback.authorize(token, embed)

    manifest = json_response(get(build_conn(), media(base, "manifest.json", token)), 200)
    assert manifest["video"]["status"] == "scheduled"

    for path <- ["playlist.m3u8", "v1/h264_hd.mp4", "thumbnail.jpg", "dynamic.jpg"] do
      assert get(build_conn(), media(base, path, token)).status == 401
    end

    image_conn =
      build_conn()
      |> Map.put(:host, image_host())
      |> get("/#{context.public_id}.jpg?" <> URI.encode_query(%{token: token}))

    assert image_conn.status == 401

    session = Playback.dashboard_session(embed)
    preview = json_response(get(build_conn(), media(base, "manifest.json", session.token)), 200)
    refute preview["video"]["status"] == "scheduled"
    assert get(build_conn(), media(base, "playlist.m3u8", session.token)).status == 200
  end

  test "access cannot be changed while a release is pending", context do
    {:ok, _embed} = Release.schedule(context.embed, in_seconds(3600))

    for visibility <- ["public", "private"] do
      conn =
        api(context.key)
        |> put("/api/v1/videos/#{context.embed.hash}", %{visibility: visibility})

      assert %{"error" => "This video has a scheduled release." <> _} = json_response(conn, 400)
    end

    conn =
      api(context.key)
      |> put("/api/v1/videos/#{context.embed.hash}", %{
        visibility: "public",
        release_at: System.system_time(:second) + 60
      })

    assert json_response(conn, 400)["error"] =~ "cannot change visibility"
  end

  test "video responses can be sent back as updates", context do
    path = "/api/v1/videos/#{context.embed.hash}"
    body = json_response(api(context.key) |> get(path), 200)
    assert %{"visibility" => "public", "release_at" => nil} = body

    conn = api(context.key) |> put(path, Map.take(body, ["name", "visibility", "release_at"]))
    assert json_response(conn, 200)["release_at"] == nil
    refute Release.pending?(Repo.get!(Embed, context.embed.id))

    {:ok, _embed} = Release.schedule(context.embed, in_seconds(3600))
    body = json_response(api(context.key) |> get(path), 200)
    assert %{"visibility" => "private", "release_at" => release_at} = body

    conn =
      api(context.key)
      |> put(path, %{name: "Renamed", visibility: "private", release_at: release_at})

    assert %{"name" => "Renamed", "release_at" => ^release_at} = json_response(conn, 200)

    conn = api(context.key) |> put(path, %{name: "Again", release_at: "soon"})
    assert conn.status == 400
    assert json_response(api(context.key) |> get(path), 200)["name"] == "Renamed"
  end

  test "a release stuck in publishing is queued again by the sweep", context do
    {:ok, _embed} = Release.schedule(context.embed, in_seconds(3600))

    Repo.update_all(from(e in Embed, where: e.id == ^context.embed.id),
      set: [release_at: in_seconds(-120), playback_status: :publishing]
    )

    assert Release.due_embed_ids() == [context.embed.id]
    assert :ok = ReleaseWorker.perform(job(%{}))
    assert_receive {:storage_visibility, _id, :public}
    assert %Embed{release_at: nil, playback_status: :public} = Repo.get!(Embed, context.embed.id)
  end

  test "the release worker publishes due releases and completes them after storage", context do
    {:ok, _embed} = Release.schedule(context.embed, in_seconds(3600))
    assert_receive {:storage_visibility, _id, :private}

    assert {:snooze, seconds} = ReleaseWorker.perform(job(%{"embed_id" => context.embed.id}))
    assert seconds in 3590..3600
    assert Release.due_embed_ids() == []

    Repo.update_all(from(e in Embed, where: e.id == ^context.embed.id),
      set: [release_at: in_seconds(-1)]
    )

    assert Release.due_embed_ids() == [context.embed.id]
    assert :ok = ReleaseWorker.perform(job(%{}))
    assert_receive {:storage_visibility, _id, :public}

    embed = Repo.get!(Embed, context.embed.id)
    assert %{release_at: nil, playback_visibility: :public, playback_status: :public} = embed

    manifest = json_response(get(build_conn(), "/api/v1/#{context.public_id}"), 200)
    refute manifest["video"]["status"] == "scheduled"
    refute Map.has_key?(manifest, "release_at")
    assert :ok = ReleaseWorker.perform(job(%{"embed_id" => context.embed.id}))
  end

  test "release_at null publishes immediately and invalid times are rejected", context do
    path = "/api/v1/videos/#{context.embed.hash}"

    for value <- ["tomorrow", "2099-06-01T18:00:00", 0] do
      conn = api(context.key) |> put(path, %{release_at: value})
      assert json_response(conn, 400)["error"] =~ "release_at must be"
    end

    conn = api(context.key) |> put(path, %{release_at: System.system_time(:second) - 10})
    assert json_response(conn, 400)["error"] == "release_at must be in the future."

    conn = api(context.key) |> put(path, %{release_at: nil})
    assert %{"release_at" => nil} = json_response(conn, 200)
    refute_received {:storage_visibility, _id, _visibility}

    conn = api(context.key) |> put(path, %{release_at: "2099-06-01T18:00:00+02:00"})
    assert %{"release_at" => 4_084_012_800} = json_response(conn, 200)

    conn = api(context.key) |> put(path, %{release_at: nil})
    assert %{"release_at" => nil, "visibility" => "public"} = json_response(conn, 200)
    assert_receive {:storage_visibility, _id, :public}
  end

  test "videos can be created with a release time", context do
    release_at = System.system_time(:second) + 600
    conn = api(context.key) |> post("/api/v1/videos", %{name: "Launch", release_at: release_at})
    assert %{"id" => id, "release_at" => ^release_at} = json_response(conn, 200)
    assert Release.pending?(PublicApi.get_embed(context.space, id))

    conn =
      api(context.key)
      |> post("/api/v1/videos", %{visibility: "private", release_at: release_at})

    assert conn.status == 400

    Process.put(:playback_available, false)
    conn = api(context.key) |> post("/api/v1/videos", %{release_at: release_at})
    assert json_response(conn, 400)["error"] =~ "Private playback is unavailable"
  end

  test "only public videos can be scheduled, with private playback available", context do
    Process.put(:playback_available, false)
    assert {:error, :playback_unavailable} = Release.schedule(context.embed, in_seconds(60))

    Process.put(:playback_available, true)
    {:ok, private} = Embeds.create_video_embed(context.space, %{visibility: :private})
    assert {:error, :playback_private} = Release.schedule(private, in_seconds(60))
    assert {:error, :release_in_past} = Release.schedule(context.embed, in_seconds(-60))
    assert {:error, :not_scheduled} = Release.release_now(context.embed)
  end

  test "collections list pending releases without media", context do
    {:ok, _embed} = Release.schedule(context.embed, in_seconds(3600))

    {:ok, %{embeds: [payload]}} = PublicApi.jwt_collection_response(context.space, nil)

    assert payload["id"] == context.public_id
    assert payload["video"]["status"] == "scheduled"
    assert payload["video"]["renditions"] == []
    assert payload["subtitles"] == [] and payload["audio_tracks"] == []
  end

  defp in_seconds(seconds), do: DateTime.add(DateTime.utc_now(), seconds, :second)

  defp job(args), do: %Oban.Job{args: args, attempt: 1}

  defp media(base, path, token),
    do: base <> "/" <> path <> "?" <> URI.encode_query(%{token: token})

  defp image_host, do: System.get_env("MAVE_IMAGE_HOST") || "www.example.com"

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
