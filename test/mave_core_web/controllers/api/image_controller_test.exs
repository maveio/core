defmodule MaveCoreWeb.Api.ImageControllerTest do
  use MaveCoreWeb.ConnCase

  import ExUnit.CaptureLog

  alias MaveCore.Accounts
  alias MaveCore.Embeds
  alias MaveCore.Media.Storage
  alias MaveCore.Repo
  alias MaveCore.TestSupport.FlowStorageAdapterStub

  setup context do
    if context[:integration] do
      original_storage_module = Application.get_env(:mave_core, :storage_module)
      Application.put_env(:mave_core, :storage_module, Storage)

      on_exit(fn -> restore_env(:storage_module, original_storage_module) end)

      {:ok, user} =
        Accounts.create_user(
          "image-integration-#{System.unique_integer([:positive])}@example.com"
        )

      space =
        user.current_space_membership.space
        |> Ecto.Changeset.change(hash: "ubg50")
        |> Repo.update!()

      {:ok, embed} = Embeds.create_video_embed(space, %{name: "Seeded integration video"})

      embed
      |> Ecto.Changeset.change(hash: "LeDE9v86ye")
      |> Repo.update!()
    end

    :ok
  end

  @tag :integration
  test "GET /{mave_id}.jpg generates and returns image", %{conn: conn} do
    # Uses seeded data - mave_id = space_hash + embed_hash
    space = "ubg50"
    embed = "LeDE9v86ye"
    mave_id = space <> embed
    time = "4"

    conn = get(conn, "/#{mave_id}.jpg?time=#{time}&width=100")

    assert response(conn, 200)
    assert response_content_type(conn, :jpeg)

    # Verify content length > 0
    assert byte_size(conn.resp_body) > 0

    # Optional: Verify headers
    assert get_resp_header(conn, "cache-control") == ["public, max-age=604800, immutable"]
  end

  @tag :integration
  test "GET /{mave_id}.jpg returns 200 for out-of-range time (falls back to last frame)", %{
    conn: conn
  } do
    space = "ubg50"
    embed = "LeDE9v86ye"
    mave_id = space <> embed
    # Out of range (video is ~10s)
    time = "100"

    conn = get(conn, "/#{mave_id}.jpg?time=#{time}")

    # Expect 200 OK now, falling back to last frame
    assert response(conn, 200)
    assert response_content_type(conn, :jpeg)
  end

  @tag :integration
  test "GET /{mave_id}.webp returns webp content type", %{conn: conn} do
    original_storage_module = Application.get_env(:mave_core, :storage_module)
    Application.put_env(:mave_core, :storage_module, FlowStorageAdapterStub)
    FlowStorageAdapterStub.reset!()

    on_exit(fn ->
      restore_env(:storage_module, original_storage_module)
      FlowStorageAdapterStub.reset!()
    end)

    space_hash = "fast1"
    embed_hash = "WebpCache1"
    region = MaveCore.Spaces.get_region(space_hash)
    bucket = FlowStorageAdapterStub.bucket_for_space(space_hash, region)
    cached_webp = "cached webp"

    assert {:ok, _} =
             FlowStorageAdapterStub.put(
               bucket,
               "#{embed_hash}/manifest.json",
               Jason.encode!(%{video: %{version: 1}}),
               "application/json",
               region
             )

    assert {:ok, _} =
             FlowStorageAdapterStub.put_public(
               bucket,
               "#{embed_hash}/_images/v1/#{embed_hash}_0.0_w100.webp",
               cached_webp,
               "image/webp",
               region
             )

    conn = get(conn, "/#{space_hash}#{embed_hash}.webp?time=0&width=100")

    assert response(conn, 200) == cached_webp
    assert get_resp_header(conn, "content-type") == ["image/webp"]
  end

  test "GET /{mave_id}.png returns unsupported format error", %{conn: conn} do
    space = "ubg50"
    embed = "LeDE9v86ye"
    mave_id = space <> embed

    conn = get(conn, "/#{mave_id}.png?time=0")

    assert response(conn, 400)
    assert conn.resp_body =~ "Unsupported format"
  end

  test "coalesces nearby times and dimensions onto a canonical cached variant", %{conn: conn} do
    original_storage_module = Application.get_env(:mave_core, :storage_module)
    Application.put_env(:mave_core, :storage_module, FlowStorageAdapterStub)
    FlowStorageAdapterStub.reset!()

    on_exit(fn ->
      restore_env(:storage_module, original_storage_module)
      FlowStorageAdapterStub.reset!()
    end)

    space_hash = "fast1"
    embed_hash = "Canonical1"
    region = MaveCore.Spaces.get_region(space_hash)
    bucket = FlowStorageAdapterStub.bucket_for_space(space_hash, region)
    mave_id = space_hash <> embed_hash
    cached_image = "canonical image"

    assert {:ok, _} =
             FlowStorageAdapterStub.put(
               bucket,
               "#{embed_hash}/manifest.json",
               Jason.encode!(%{video: %{version: 1}}),
               "application/json",
               region
             )

    put_test_playlists(bucket, embed_hash, region)

    canonical_path = "#{embed_hash}/_images/v1/#{embed_hash}_1.2_w160.webp"

    assert {:ok, _} =
             FlowStorageAdapterStub.put_public(
               bucket,
               canonical_path,
               cached_image,
               "image/webp",
               region
             )

    first = get(conn, "/#{mave_id}.webp?time=1.24&width=100")
    second = get(recycle(first), "/#{mave_id}.webp?time=1.23&width=200")

    assert response(first, 200) == cached_image
    assert response(second, 200) == cached_image
  end

  defmodule FailingFlame do
    def call(_pool, _fun), do: raise("connect to mave_core@10.1.2.3 failed")
  end

  defmodule ClaimingCoordinator do
    def claim(_key, _ttl_ms), do: {:ok, "image-owner"}
    def release(_key, "image-owner"), do: :ok
  end

  test "does not expose internal failure details to image clients", %{conn: conn} do
    original_storage_module = Application.get_env(:mave_core, :storage_module)
    original_flame_caller = Application.get_env(:mave_core, :image_flame_caller)
    original_coordinator = Application.get_env(:mave_core, :image_generation_coordinator_module)
    Application.put_env(:mave_core, :storage_module, FlowStorageAdapterStub)
    Application.put_env(:mave_core, :image_flame_caller, FailingFlame)
    Application.put_env(:mave_core, :image_generation_coordinator_module, ClaimingCoordinator)
    FlowStorageAdapterStub.reset!()

    on_exit(fn ->
      restore_env(:storage_module, original_storage_module)
      restore_env(:image_flame_caller, original_flame_caller)
      restore_env(:image_generation_coordinator_module, original_coordinator)
      FlowStorageAdapterStub.reset!()
    end)

    email = "image-failure-#{System.unique_integer([:positive])}@example.com"
    {:ok, user} = Accounts.create_user(email)
    space = user.current_space_membership.space
    {:ok, embed} = Embeds.create_video_embed(space, %{name: "Failing Image Target"})
    space_hash = space.hash
    embed_hash = embed.hash
    region = MaveCore.Spaces.get_region(space_hash)
    bucket = FlowStorageAdapterStub.bucket_for_space(space_hash, region)

    assert {:ok, _} =
             FlowStorageAdapterStub.put(
               bucket,
               "#{embed_hash}/manifest.json",
               Jason.encode!(%{video: %{version: 1}}),
               "application/json",
               region
             )

    put_test_playlists(bucket, embed_hash, region)

    log =
      capture_log(fn ->
        conn = get(conn, "/#{space_hash}#{embed_hash}.jpg?time=1")

        assert response(conn, 500) == "Failed to generate image"
        assert get_resp_header(conn, "cache-control") == ["no-store"]
      end)

    assert log =~ "10.1.2.3"
  end

  test "GET /invalid.jpg returns bad request for invalid mave_id", %{conn: conn} do
    conn = get(conn, "/invalid.jpg?time=0")

    assert response(conn, 400)
    assert conn.resp_body =~ "Invalid mave_id format"
  end

  for query <- [
        "time=1second",
        "time=-1",
        "width=0",
        "width=-1",
        "width=100px",
        "height=99999999999"
      ] do
    test "rejects invalid image parameter #{query}", %{conn: conn} do
      conn = get(conn, "/fast1ImageTest1.jpg?#{unquote(query)}")

      assert response(conn, 400) == "Invalid image parameters"
    end
  end

  test "GET /{mave_id}.jpg returns 404 for deleted embeds", %{conn: conn} do
    email = "image-deleted-#{System.unique_integer([:positive])}@example.com"
    {:ok, user} = Accounts.create_user(email)
    space = user.current_space_membership.space
    {:ok, embed} = Embeds.create_video_embed(space, %{name: "Deleted Image Target"})
    assert {:ok, _deleted} = Embeds.delete_embed(embed)

    conn = get(conn, "/#{space.hash}#{embed.hash}.jpg?time=0")

    assert response(conn, 404) == "Not found"
  end

  test "limits new AVIF variants per embed while continuing to serve cached variants", %{
    conn: conn
  } do
    original_storage_module = Application.get_env(:mave_core, :storage_module)
    original_budget = Application.get_env(:mave_core, :image_generation_budget)

    Application.put_env(:mave_core, :storage_module, FlowStorageAdapterStub)
    Application.put_env(:mave_core, :image_generation_budget, per_minute: 0, per_day: 0)
    FlowStorageAdapterStub.reset!()

    on_exit(fn ->
      restore_env(:storage_module, original_storage_module)
      restore_env(:image_generation_budget, original_budget)
      FlowStorageAdapterStub.reset!()
    end)

    space_hash = "fast1"
    embed_hash = "RateLimit1"
    region = MaveCore.Spaces.get_region(space_hash)
    bucket = FlowStorageAdapterStub.bucket_for_space(space_hash, region)
    mave_id = space_hash <> embed_hash

    manifest_json = Jason.encode!(%{video: %{version: 1}})

    assert {:ok, _} =
             FlowStorageAdapterStub.put(
               bucket,
               "#{embed_hash}/manifest.json",
               manifest_json,
               "application/json",
               region
             )

    put_test_playlists(bucket, embed_hash, region)

    denied_conn = get(conn, "/#{mave_id}.avif?time=1&width=100000")

    assert response(denied_conn, 429) == "Image generation rate limit exceeded"
    assert get_resp_header(denied_conn, "cache-control") == ["no-store"]
    assert [retry_after] = get_resp_header(denied_conn, "retry-after")
    assert {retry_after_seconds, ""} = Integer.parse(retry_after)
    assert retry_after_seconds > 0

    output_path = "#{embed_hash}/_images/v1/#{embed_hash}_4.4_w1280.avif"
    cached_avif = "cached avif"

    assert {:ok, _} =
             FlowStorageAdapterStub.put_public(
               bucket,
               output_path,
               cached_avif,
               "image/avif",
               region
             )

    cached_conn = get(recycle(denied_conn), "/#{mave_id}.avif?time=101&width=99999")

    assert response(cached_conn, 200) == cached_avif
  end

  defp restore_env(key, nil), do: Application.delete_env(:mave_core, key)
  defp restore_env(key, value), do: Application.put_env(:mave_core, key, value)

  defp put_test_playlists(bucket, embed_hash, region) do
    assert {:ok, _} =
             FlowStorageAdapterStub.put(
               bucket,
               "#{embed_hash}/v1/playlist.m3u8",
               "#EXTM3U\n#EXT-X-STREAM-INF:BANDWIDTH=2800000,RESOLUTION=1280x720\n720p/playlist.m3u8\n",
               "application/vnd.apple.mpegurl",
               region
             )

    assert {:ok, _} =
             FlowStorageAdapterStub.put(
               bucket,
               "#{embed_hash}/v1/720p/playlist.m3u8",
               "#EXTM3U\n#EXTINF:4.500000,\nsegment0.m4s\n#EXT-X-ENDLIST\n",
               "application/vnd.apple.mpegurl",
               region
             )
  end
end
