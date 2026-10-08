defmodule MaveCoreWeb.Api.VideosControllerTest do
  use MaveCoreWeb.ConnCase

  import Ecto.Query

  alias MaveCore.Accounts
  alias MaveCore.Assets.{AudioTrack, Subtitle, Video}
  alias MaveCore.Embeds
  alias MaveCore.Flow
  alias MaveCore.Flow.Run, as: FlowRun
  alias MaveCore.PublicApi
  alias MaveCore.Repo
  alias MaveCore.Spaces
  alias MaveCore.TestSupport.FlowStorageAdapterStub

  defmodule VideoBlockedUsageLimits do
    @behaviour MaveCore.UsageLimits

    def can_create_video_embed?(_space), do: {:error, :embed_limit_reached}
    def can_add_space_member?(_space, _role), do: :ok
    def can_view_space_data?(_space), do: :ok
  end

  setup {Req.Test, :verify_on_exit!}

  setup context do
    if context[:manifest_storage] do
      previous = Application.get_env(:mave_core, :flow_storage_adapter)

      Application.put_env(
        :mave_core,
        :flow_storage_adapter,
        FlowStorageAdapterStub
      )

      FlowStorageAdapterStub.reset!()
      on_exit(fn -> restore_env(:flow_storage_adapter, previous) end)
    end

    :ok
  end

  setup do
    email = "api-videos-#{System.unique_integer([:positive])}@example.com"
    {:ok, user} = Accounts.create_user(email)
    space = user.current_space_membership.space
    {:ok, key} = Spaces.create_key(space)
    video = Embeds.create_video_embed(space, %{name: "Public Video"}) |> elem(1)
    folder = Embeds.create_folder_embed(space, %{name: "Public Folder"}) |> elem(1)

    old_resolver = Application.get_env(:mave_core, :public_http_url_resolver)

    Application.put_env(:mave_core, :public_http_url_resolver, fn _host ->
      {:ok, [{93, 184, 216, 34}]}
    end)

    auth =
      key
      |> then(&Spaces.display_api_key(&1.key, &1.secret))
      |> then(&"Bearer #{&1}")

    previous_req_options = Req.default_options()

    on_exit(fn ->
      Req.default_options(previous_req_options)
      restore_env(:public_http_url_resolver, old_resolver)
    end)

    %{space: space, auth: auth, video: video, folder: folder, key: key}
  end

  test "GET /api/v1/videos returns old list shape and auth updates last_used_at", %{
    conn: conn,
    space: space,
    auth: auth,
    video: video,
    folder: folder,
    key: key
  } do
    conn =
      conn
      |> put_req_header("authorization", auth)
      |> get(~p"/api/v1/videos?show_collections=true")

    assert %{
             "object" => "list",
             "space_id" => space_id,
             "current_page" => 1,
             "total_items" => 2,
             "data" => data
           } = json_response(conn, 200)

    assert space_id == space.id
    assert String.length(space_id) == 22

    assert Enum.any?(
             data,
             &(&1["id"] == "#{space.hash}#{video.hash}" and &1["object"] == "video")
           )

    assert Enum.any?(
             data,
             &(&1["id"] == "#{space.hash}#{folder.hash}" and &1["object"] == "collection")
           )

    assert Spaces.get_key_for_space(space, key.id).last_used_at
  end

  test "read-only API keys keep reads working but reject video mutations", %{
    conn: conn,
    auth: auth,
    key: key,
    space: space,
    video: video
  } do
    assert {:ok, _key} = Spaces.make_key_read_only(key)

    read_conn =
      conn
      |> put_req_header("authorization", auth)
      |> get(~p"/api/v1/videos/#{video.hash}")

    assert %{"name" => "Public Video"} = json_response(read_conn, 200)

    create_conn =
      build_conn()
      |> put_req_header("authorization", auth)
      |> post(~p"/api/v1/videos", %{"name" => "Blocked Video"})

    assert %{"error" => "This API key is read-only"} = json_response(create_conn, 403)

    update_conn =
      build_conn()
      |> put_req_header("authorization", auth)
      |> put(~p"/api/v1/videos/#{video.hash}", %{"name" => "Blocked Rename"})

    assert %{"error" => "This API key is read-only"} = json_response(update_conn, 403)

    delete_conn =
      build_conn()
      |> put_req_header("authorization", auth)
      |> delete(~p"/api/v1/videos/#{video.hash}")

    assert %{"error" => "This API key is read-only"} = json_response(delete_conn, 403)
    assert PublicApi.get_embed(space, video.hash).asset.name == "Public Video"
  end

  test "GET /api/v1/videos identifies the authenticated space when the library is empty", %{
    conn: conn,
    space: space,
    auth: auth,
    video: video,
    folder: folder
  } do
    {:ok, _video} = Embeds.delete_embed(video)
    {:ok, _folder} = Embeds.delete_embed(folder)

    conn =
      conn
      |> put_req_header("authorization", auth)
      |> get(~p"/api/v1/videos")

    assert %{"data" => [], "space_id" => space_id} = json_response(conn, 200)
    assert space_id == space.id
    assert String.length(space_id) == 22
  end

  test "GET /api/v1/videos allows super admin sessions during maintenance", %{
    conn: conn,
    space: space,
    auth: auth,
    video: video
  } do
    with_flow_admin("api-videos-admin@example.com", fn ->
      with_maintenance(fn ->
        conn =
          conn
          |> authenticated_conn("api-videos-admin@example.com")
          |> put_req_header("authorization", auth)
          |> get(~p"/api/v1/videos")

        assert %{"data" => data} = json_response(conn, 200)
        assert Enum.any?(data, &(&1["id"] == "#{space.hash}#{video.hash}"))
      end)
    end)
  end

  test "GET /api/v1/videos returns maintenance without a super admin session", %{
    conn: conn,
    auth: auth
  } do
    with_maintenance(fn ->
      conn =
        conn
        |> put_req_header("authorization", auth)
        |> get(~p"/api/v1/videos")

      assert json_response(conn, 503)["error"] == "maintenance"
    end)
  end

  test "GET /v1/videos works on the configured API host", %{
    conn: conn,
    space: space,
    auth: auth,
    video: video
  } do
    with_env("MAVE_API_HOST", "api.mave.io", fn ->
      conn =
        conn
        |> with_host("api.mave.io")
        |> put_req_header("authorization", auth)
        |> get(~p"/v1/videos")

      assert %{"data" => data} = json_response(conn, 200)
      assert Enum.any?(data, &(&1["id"] == "#{space.hash}#{video.hash}"))
    end)
  end

  test "GET /v1/videos is not exposed on non-API hosts", %{conn: conn, auth: auth} do
    with_env("MAVE_API_HOST", "api.mave.io", fn ->
      conn =
        conn
        |> with_host("dash.mave.io")
        |> put_req_header("authorization", auth)
        |> get(~p"/v1/videos")

      assert response(conn, 404) == "Not found"
    end)
  end

  test "GET /api/v1/videos accepts a public collection id filter", %{
    conn: conn,
    auth: auth,
    space: space,
    video: video,
    folder: folder
  } do
    assert {:ok, _moved} = Embeds.move_embed(video, folder)

    conn =
      conn
      |> put_req_header("authorization", auth)
      |> get(~p"/api/v1/videos?collection=#{space.hash <> folder.hash}")

    assert %{"data" => [item], "total_items" => 1} = json_response(conn, 200)
    assert item["id"] == "#{space.hash}#{video.hash}"
  end

  test "GET /api/v1/videos ignores misspelled show_colletions param", %{
    conn: conn,
    auth: auth,
    space: space,
    folder: folder
  } do
    conn =
      conn
      |> put_req_header("authorization", auth)
      |> get(~p"/api/v1/videos?show_colletions=true")

    assert %{"data" => data} = json_response(conn, 200)

    refute Enum.any?(
             data,
             &(&1["id"] == "#{space.hash}#{folder.hash}" or &1["object"] == "collection")
           )
  end

  test "GET /api/v1/videos filters uploaded state and normalizes invalid pagination", %{
    conn: conn,
    auth: auth,
    space: space,
    video: video
  } do
    current_video =
      %Video{}
      |> Video.changeset(%{
        asset_id: video.asset_id,
        status: "ready",
        file_name: "public-video.mp4"
      })
      |> Repo.insert!()

    video.asset
    |> Ecto.Changeset.change(current_video_id: current_video.id)
    |> Repo.update!()

    conn =
      conn
      |> put_req_header("authorization", auth)
      |> get(~p"/api/v1/videos?uploaded=true&page=not-a-page&per_page=500")

    assert %{"current_page" => 1, "data" => data} = json_response(conn, 200)
    assert Enum.map(data, & &1["id"]) == ["#{space.hash}#{video.hash}"]

    conn =
      build_conn()
      |> put_req_header("authorization", auth)
      |> get(~p"/api/v1/videos?uploaded=false&page=-1&per_page=-20")

    assert %{"current_page" => 1, "data" => data} = json_response(conn, 200)
    refute Enum.any?(data, &(&1["id"] == "#{space.hash}#{video.hash}"))
  end

  test "GET /api/v1/videos archived root list excludes videos inside collections", %{
    conn: conn,
    auth: auth,
    space: space
  } do
    archived_root =
      Embeds.create_video_embed(space, %{name: "Archived Root", archived: true}) |> elem(1)

    archived_folder =
      Embeds.create_folder_embed(space, %{name: "Archived Folder", archived: true}) |> elem(1)

    archived_child =
      Embeds.create_video_embed(space, %{
        name: "Archived Child",
        parent_folder_id: archived_folder.id,
        archived: true
      })
      |> elem(1)

    conn =
      conn
      |> put_req_header("authorization", auth)
      |> get(~p"/api/v1/videos?archived=true")

    assert %{"data" => data} = json_response(conn, 200)
    ids = Enum.map(data, & &1["id"])
    assert "#{space.hash}#{archived_root.hash}" in ids
    refute "#{space.hash}#{archived_child.hash}" in ids
  end

  test "GET /api/v1/videos accepts basic auth too", %{conn: conn, key: key} do
    basic_auth = Plug.BasicAuth.encode_basic_auth(key.key, key.secret)

    conn =
      conn
      |> put_req_header("authorization", basic_auth)
      |> get(~p"/api/v1/videos")

    assert %{"object" => "list", "data" => data} = json_response(conn, 200)
    assert is_list(data)
  end

  test "GET /api/v1/videos/:hash returns old video response shape", %{
    conn: conn,
    auth: auth,
    space: space,
    video: video
  } do
    conn =
      conn
      |> put_req_header("authorization", auth)
      |> get(~p"/api/v1/videos/#{video.hash}")

    assert %{
             "id" => id,
             "name" => "Public Video",
             "object" => "video",
             "poster_image" => poster_image,
             "renditions" => renditions,
             "subtitles" => subtitles
           } = json_response(conn, 200)

    assert id == "#{space.hash}#{video.hash}"
    assert is_binary(poster_image)
    assert is_list(renditions)
    assert subtitles == []
  end

  test "GET /api/v1/videos/:hash also accepts the public id returned by the list endpoint", %{
    conn: conn,
    auth: auth,
    space: space,
    video: video
  } do
    conn =
      conn
      |> put_req_header("authorization", auth)
      |> get(~p"/api/v1/videos/#{space.hash <> video.hash}")

    assert %{"id" => id, "name" => "Public Video", "object" => "video"} = json_response(conn, 200)
    assert id == "#{space.hash}#{video.hash}"
  end

  test "GET /api/v1/videos/:hash cannot read another space's public id", %{
    conn: conn,
    auth: auth
  } do
    {other_space, other_video} = other_space_video_fixture()

    conn =
      conn
      |> put_req_header("authorization", auth)
      |> get(~p"/api/v1/videos/#{other_space.hash <> other_video.hash}")

    assert %{"error" => "This video embed does not exist."} = json_response(conn, 404)
  end

  test "GET /api/v1/videos/:hash returns old rendition size list", %{
    conn: conn,
    auth: auth,
    video: video
  } do
    current_video =
      %Video{}
      |> Video.changeset(%{
        asset_id: video.asset_id,
        status: "ready",
        file_name: "public-video.mp4",
        max_width: 1920,
        max_height: 1080,
        original_file_size: 12_345_678
      })
      |> Repo.insert!()

    video.asset
    |> Ecto.Changeset.change(current_video_id: current_video.id)
    |> Repo.update!()

    video_id_db = MaveCore.LegacyShortUUID.dump!(current_video.id)
    now = DateTime.utc_now() |> DateTime.truncate(:microsecond)

    Repo.insert_all("renditions", [
      %{
        id: MaveCore.LegacyShortUUID.dump!(Ecto.UUID.generate()),
        video_id: video_id_db,
        rendition_key: "videos/public-video-sd.mp4",
        type: "video",
        codec: "h264",
        container: "mp4",
        size: "sd",
        progress: 100,
        file_size: 12_345,
        inserted_at: now,
        updated_at: now
      },
      %{
        id: MaveCore.LegacyShortUUID.dump!(Ecto.UUID.generate()),
        video_id: video_id_db,
        rendition_key: "videos/public-video-hd.mp4",
        type: "video",
        codec: "h264",
        container: "mp4",
        size: "hd",
        progress: 100,
        file_size: 23_456,
        inserted_at: now,
        updated_at: now
      },
      %{
        id: MaveCore.LegacyShortUUID.dump!(Ecto.UUID.generate()),
        video_id: video_id_db,
        rendition_key: "images/public-video-poster.jpg",
        type: "poster",
        codec: "jpg",
        container: "jpg",
        size: nil,
        progress: 100,
        file_size: 3_210,
        inserted_at: now,
        updated_at: now
      },
      %{
        id: MaveCore.LegacyShortUUID.dump!(Ecto.UUID.generate()),
        video_id: video_id_db,
        rendition_key: "videos/public-video-fhd.mp4",
        type: "video",
        codec: "h264",
        container: "mp4",
        size: "fhd",
        progress: 80,
        file_size: 34_567,
        inserted_at: now,
        updated_at: now
      }
    ])

    conn =
      conn
      |> put_req_header("authorization", auth)
      |> get(~p"/api/v1/videos/#{video.hash}")

    assert %{"renditions" => ["sd", "hd"]} = json_response(conn, 200)
  end

  test "GET /api/v1/videos/:hash keeps audio tracks out of the old video response shape", %{
    conn: conn,
    auth: auth,
    video: video
  } do
    current_video =
      %Video{}
      |> Video.changeset(%{
        asset_id: video.asset_id,
        status: "ready",
        file_name: "public-video.mp4",
        max_width: 1920,
        max_height: 1080,
        original_file_size: 12_345_678
      })
      |> Repo.insert!()

    video.asset
    |> Ecto.Changeset.change(current_video_id: current_video.id)
    |> Repo.update!()

    %AudioTrack{}
    |> AudioTrack.changeset(%{
      video_id: current_video.id,
      label: "Original",
      language: "en",
      default: true,
      codec: "mp3",
      file_size: 4_321,
      filename: "audio.mp3"
    })
    |> Repo.insert!()

    conn =
      conn
      |> put_req_header("authorization", auth)
      |> get(~p"/api/v1/videos/#{video.hash}")

    refute Map.has_key?(json_response(conn, 200), "audio_tracks")
  end

  test "GET /api/v1/videos/:hash returns subtitle language codes in the old response shape", %{
    conn: conn,
    auth: auth,
    video: video
  } do
    current_video =
      %Video{}
      |> Video.changeset(%{
        asset_id: video.asset_id,
        status: "ready",
        file_name: "public-video.mp4",
        max_width: 1920,
        max_height: 1080,
        original_file_size: 12_345_678
      })
      |> Repo.insert!()

    video.asset
    |> Ecto.Changeset.change(current_video_id: current_video.id)
    |> Repo.update!()

    %Subtitle{}
    |> Subtitle.changeset(%{
      video_id: current_video.id,
      language: "en",
      path: "#{video.hash}/subtitle_en.vtt"
    })
    |> Repo.insert!()

    conn =
      conn
      |> put_req_header("authorization", auth)
      |> get(~p"/api/v1/videos/#{video.hash}")

    assert %{"subtitles" => ["en"]} = json_response(conn, 200)
  end

  test "GET /api/v1/videos list uses the same old subtitle and audio track contract", %{
    conn: conn,
    auth: auth,
    space: space,
    video: video
  } do
    current_video =
      %Video{}
      |> Video.changeset(%{
        asset_id: video.asset_id,
        status: "ready",
        file_name: "public-video.mp4",
        max_width: 1920,
        max_height: 1080,
        original_file_size: 12_345_678
      })
      |> Repo.insert!()

    video.asset
    |> Ecto.Changeset.change(current_video_id: current_video.id)
    |> Repo.update!()

    %AudioTrack{}
    |> AudioTrack.changeset(%{
      video_id: current_video.id,
      label: "Original",
      language: "en",
      default: true,
      codec: "mp3",
      file_size: 4_321,
      filename: "audio.mp3"
    })
    |> Repo.insert!()

    %Subtitle{}
    |> Subtitle.changeset(%{
      video_id: current_video.id,
      language: "en",
      path: "#{video.hash}/subtitle_en.vtt"
    })
    |> Repo.insert!()

    conn =
      conn
      |> put_req_header("authorization", auth)
      |> get(~p"/api/v1/videos")

    %{"data" => data} = json_response(conn, 200)
    item = Enum.find(data, &(&1["id"] == "#{space.hash}#{video.hash}"))

    assert item["subtitles"] == ["en"]
    refute Map.has_key?(item, "audio_tracks")
  end

  test "POST /api/v1/videos returns 400 when input_url cannot be fetched", %{
    conn: conn,
    auth: auth,
    space: space
  } do
    Req.default_options(plug: {Req.Test, __MODULE__})

    Req.Test.expect(__MODULE__, fn conn ->
      assert conn.method == "GET"
      assert get_req_header(conn, "range") == ["bytes=0-0"]
      send_resp(conn, 404, "not found")
    end)

    before_count = PublicApi.count_videos(space, show_collections: true)

    conn =
      conn
      |> put_req_header("authorization", auth)
      |> post(~p"/api/v1/videos", %{
        "name" => "Dead remote video",
        "input_url" => "https://example.com/missing.mp4"
      })

    assert %{"error" => "Could not fetch input_url."} = json_response(conn, 400)
    assert PublicApi.count_videos(space, show_collections: true) == before_count
  end

  test "POST /api/v1/videos rejects input_url hosts that resolve to internal addresses", %{
    conn: conn,
    auth: auth,
    space: space
  } do
    Req.default_options(plug: {Req.Test, __MODULE__})
    before_count = PublicApi.count_videos(space, show_collections: true)

    conn =
      conn
      |> put_req_header("authorization", auth)
      |> post(~p"/api/v1/videos", %{
        "name" => "Internal URL",
        "input_url" => "http://127.0.0.1:4000/"
      })

    assert %{"error" => "input_url host is not allowed."} = json_response(conn, 400)
    assert PublicApi.count_videos(space, show_collections: true) == before_count
  end

  test "POST /api/v1/videos accepts input_url basic auth credentials", %{
    conn: conn,
    auth: auth,
    space: space
  } do
    Req.default_options(plug: {Req.Test, __MODULE__})
    input_url = "https://user:pa%24%24@example.com/protected.mp4"

    Req.Test.expect(__MODULE__, fn conn ->
      assert conn.method == "GET"
      assert get_req_header(conn, "range") == ["bytes=0-0"]
      assert get_req_header(conn, "authorization") == ["Basic " <> Base.encode64("user:pa$$")]
      send_resp(conn, 206, "x")
    end)

    conn =
      conn
      |> put_req_header("authorization", auth)
      |> post(~p"/api/v1/videos", %{
        "name" => "Protected remote video",
        "input_url" => input_url
      })

    assert %{"id" => public_id, "name" => "Protected remote video"} = json_response(conn, 200)
    embed_hash = String.replace_prefix(public_id, space.hash, "")

    assert %FlowRun{input: %{"input_url" => ^input_url, "embed_hash" => ^embed_hash}} =
             Repo.one!(
               from run in FlowRun,
                 where: fragment("?->>'input_url' = ?", run.input, ^input_url)
             )
  end

  test "POST /api/v1/videos rejects direct requests when the video limit is reached", %{
    conn: conn,
    auth: auth,
    space: space
  } do
    old_backend = Application.get_env(:mave_core, :usage_limits_backend)
    Application.put_env(:mave_core, :usage_limits_backend, VideoBlockedUsageLimits)

    on_exit(fn ->
      restore_env(:usage_limits_backend, old_backend)
    end)

    before_count = PublicApi.count_videos(space, show_collections: true)

    conn =
      conn
      |> put_req_header("authorization", auth)
      |> post(~p"/api/v1/videos", %{"name" => "Limit Bypass Attempt"})

    assert %{"error" => "This space has reached its video limit."} = json_response(conn, 400)
    assert PublicApi.count_videos(space, show_collections: true) == before_count
  end

  test "POST /api/v1/videos creates input_url flow runs at low priority", %{
    conn: conn,
    auth: auth,
    space: space
  } do
    old_upload_config = Application.get_env(:mave_core, :upload)

    Application.put_env(
      :mave_core,
      :upload,
      Keyword.put(old_upload_config || [], :default_template, "publish_local")
    )

    on_exit(fn ->
      restore_env(:upload, old_upload_config)
    end)

    Req.default_options(plug: {Req.Test, __MODULE__})
    input_url = "https://example.com/remote-#{System.unique_integer([:positive])}.mp4"

    Req.Test.expect(__MODULE__, fn conn ->
      assert conn.method == "GET"
      assert get_req_header(conn, "range") == ["bytes=0-0"]
      send_resp(conn, 206, "x")
    end)

    conn =
      conn
      |> put_req_header("authorization", auth)
      |> post(~p"/api/v1/videos", %{
        "name" => "Remote API video",
        "input_url" => input_url,
        "priority" => "high"
      })

    assert %{"id" => public_id, "name" => "Remote API video", "object" => "video"} =
             json_response(conn, 200)

    embed_hash = String.replace_prefix(public_id, space.hash, "")

    run =
      Repo.one!(
        from run in FlowRun,
          join: template in assoc(run, :flow_template),
          where: fragment("?->>'input_url' = ?", run.input, ^input_url),
          preload: [flow_template: template]
      )

    assert run.flow_template.slug == "publish_remote_local"
    assert run.input["space_hash"] == space.hash
    assert run.input["embed_hash"] == embed_hash
    assert run.input["priority"] == "low"
    assert run.input["durable_source_required"] == true
  end

  test "POST /api/v1/videos canonicalizes a legacy remote selection to production", %{
    conn: conn,
    auth: auth,
    space: space
  } do
    assert {:ok, _space} =
             Spaces.update_space_processing(space, %{
               "default_flow_template" => "publish_remote"
             })

    Req.default_options(plug: {Req.Test, __MODULE__})
    input_url = "https://example.com/production-remote-#{System.unique_integer([:positive])}.mp4"

    Req.Test.expect(__MODULE__, fn conn ->
      assert conn.method == "GET"
      assert get_req_header(conn, "range") == ["bytes=0-0"]
      send_resp(conn, 206, "x")
    end)

    conn =
      conn
      |> put_req_header("authorization", auth)
      |> post(~p"/api/v1/videos", %{"name" => "Production remote", "input_url" => input_url})

    assert %{"object" => "video"} = json_response(conn, 200)

    run =
      Repo.one!(
        from run in FlowRun,
          join: template in assoc(run, :flow_template),
          where: fragment("?->>'input_url' = ?", run.input, ^input_url),
          preload: [flow_template: template]
      )

    assert run.flow_template.slug == "publish_remote"
    assert run.input["durable_source_required"] == true
  end

  test "POST /api/v1/videos preserves a space-specific custom template", %{
    conn: conn,
    auth: auth,
    space: space
  } do
    slug = "custom-remote-#{System.unique_integer([:positive])}"
    assert {:ok, template} = Flow.create_template(%{"slug" => slug, "name" => "Custom Remote"})

    assert {:ok, _version} =
             Flow.create_version(template.id, %{
               "definition" => %{
                 "steps" => [
                   %{"id" => "source", "type" => "source.resolve", "name" => "Resolve Source"}
                 ]
               }
             })

    assert {:ok, _space} =
             Spaces.update_space_processing(space, %{"default_flow_template" => slug})

    Req.default_options(plug: {Req.Test, __MODULE__})
    input_url = "https://example.com/custom-remote-#{System.unique_integer([:positive])}.mp4"

    Req.Test.stub(__MODULE__, fn conn ->
      case get_req_header(conn, "range") do
        ["bytes=0-0"] -> send_resp(conn, 206, "x")
        _other -> send_resp(conn, 404, "not found")
      end
    end)

    conn =
      conn
      |> put_req_header("authorization", auth)
      |> post(~p"/api/v1/videos", %{"name" => "Custom remote", "input_url" => input_url})

    assert %{"object" => "video"} = json_response(conn, 200)

    run =
      Repo.one!(
        from run in FlowRun,
          join: template in assoc(run, :flow_template),
          where: fragment("?->>'input_url' = ?", run.input, ^input_url),
          preload: [flow_template: template]
      )

    assert run.flow_template.slug == slug
  end

  test "POST /api/v1/videos uses the configured input_url priority provider", %{
    conn: conn,
    auth: auth,
    space: space
  } do
    old_provider = Application.get_env(:mave_core, :public_api_input_url_priority_provider)
    Application.put_env(:mave_core, :public_api_input_url_priority_provider, __MODULE__)

    on_exit(fn ->
      restore_env(:public_api_input_url_priority_provider, old_provider)
    end)

    Req.default_options(plug: {Req.Test, __MODULE__})
    input_url = "https://example.com/paid-remote-#{System.unique_integer([:positive])}.mp4"

    Req.Test.expect(__MODULE__, fn conn ->
      assert conn.method == "GET"
      assert get_req_header(conn, "range") == ["bytes=0-0"]
      send_resp(conn, 206, "x")
    end)

    conn =
      conn
      |> put_req_header("authorization", auth)
      |> post(~p"/api/v1/videos", %{
        "name" => "Paid remote API video",
        "input_url" => input_url
      })

    assert %{"id" => public_id, "object" => "video"} = json_response(conn, 200)
    embed_hash = String.replace_prefix(public_id, space.hash, "")

    run =
      Repo.one!(
        from run in FlowRun,
          where: fragment("?->>'input_url' = ?", run.input, ^input_url)
      )

    assert run.input["space_hash"] == space.hash
    assert run.input["embed_hash"] == embed_hash
    assert run.input["priority"] == "import"
  end

  @tag :manifest_storage
  test "PUT /api/v1/videos/:hash renames and moves video", %{
    conn: conn,
    auth: auth,
    space: space,
    video: video,
    folder: folder
  } do
    conn =
      conn
      |> put_req_header("authorization", auth)
      |> put(~p"/api/v1/videos/#{video.hash}", %{
        "name" => "Renamed Video",
        "collection" => folder.hash
      })

    assert %{"name" => "Renamed Video"} = json_response(conn, 200)

    %{videos: videos} = Embeds.list_folder_items(space, folder)
    assert Enum.any?(videos, &(&1.hash == video.hash))
  end

  @tag :manifest_storage
  test "PUT /api/v1/videos/:hash accepts public ids for both the video and target collection", %{
    conn: conn,
    auth: auth,
    space: space,
    video: video,
    folder: folder
  } do
    conn =
      conn
      |> put_req_header("authorization", auth)
      |> put(~p"/api/v1/videos/#{space.hash <> video.hash}", %{
        "name" => "Moved Via Public IDs",
        "collection" => space.hash <> folder.hash
      })

    assert %{"name" => "Moved Via Public IDs"} = json_response(conn, 200)

    %{videos: videos} = Embeds.list_folder_items(space, folder)
    assert Enum.any?(videos, &(&1.hash == video.hash))
  end

  test "PUT /api/v1/videos/:hash cannot update another space's public id", %{
    conn: conn,
    auth: auth
  } do
    {other_space, other_video} = other_space_video_fixture()

    conn =
      conn
      |> put_req_header("authorization", auth)
      |> put(~p"/api/v1/videos/#{other_space.hash <> other_video.hash}", %{
        "name" => "Hijacked Video"
      })

    assert %{"error" => "This video embed does not exist."} = json_response(conn, 404)
    assert PublicApi.get_embed(other_space, other_video.hash).asset.name == "Other Space Video"
  end

  test "PUT /api/v1/videos/:hash cannot move into another space's collection", %{
    conn: conn,
    auth: auth,
    space: space,
    video: video
  } do
    {other_space, _other_video} = other_space_video_fixture()
    other_folder = Embeds.create_folder_embed(other_space, %{name: "Other Folder"}) |> elem(1)

    conn =
      conn
      |> put_req_header("authorization", auth)
      |> put(~p"/api/v1/videos/#{space.hash <> video.hash}", %{
        "collection" => other_space.hash <> other_folder.hash
      })

    assert %{"error" => "This collection does not seem to be part of your space."} =
             json_response(conn, 400)

    %{videos: videos} = Embeds.list_folder_items(other_space, other_folder)
    refute Enum.any?(videos, &(&1.id == video.id))
  end

  test "DELETE /api/v1/videos/:hash cannot delete another space's public id", %{
    conn: conn,
    auth: auth
  } do
    {other_space, other_video} = other_space_video_fixture()

    conn =
      conn
      |> put_req_header("authorization", auth)
      |> delete(~p"/api/v1/videos/#{other_space.hash <> other_video.hash}")

    assert %{"error" => "This video embed does not exist."} = json_response(conn, 404)
    assert PublicApi.get_embed(other_space, other_video.hash)
  end

  test "GET /api/v1/videos/owner/:hash returns owning space id", %{
    conn: conn,
    auth: auth,
    space: space,
    video: video
  } do
    conn =
      conn
      |> put_req_header("authorization", auth)
      |> get(~p"/api/v1/videos/owner/#{video.hash}")

    assert %{"space_id" => space_id} = json_response(conn, 200)
    assert space_id == space.id
  end

  test "GET /api/v1/videos/owner/:hash accepts the public id returned by the list endpoint", %{
    conn: conn,
    auth: auth,
    space: space,
    video: video
  } do
    conn =
      conn
      |> put_req_header("authorization", auth)
      |> get(~p"/api/v1/videos/owner/#{space.hash <> video.hash}")

    assert %{"space_id" => space_id} = json_response(conn, 200)
    assert space_id == space.id
  end

  test "GET /api/v1/videos/owner/:hash cannot reveal another space's owner", %{
    conn: conn,
    auth: auth
  } do
    {other_space, other_video} = other_space_video_fixture()

    conn =
      conn
      |> put_req_header("authorization", auth)
      |> get(~p"/api/v1/videos/owner/#{other_space.hash <> other_video.hash}")

    assert %{"error" => "This video embed does not exist."} = json_response(conn, 404)
  end

  test "missing auth returns 401", %{conn: conn, video: video} do
    conn = get(conn, ~p"/api/v1/videos/#{video.hash}")
    assert %{"error" => "You're not authorized to make this request"} = json_response(conn, 401)
  end

  def public_api_input_url_priority(_space, _params), do: "import"

  defp other_space_video_fixture do
    email = "api-videos-other-#{System.unique_integer([:positive])}@example.com"
    {:ok, other_user} = Accounts.create_user(email)
    other_space = other_user.current_space_membership.space
    other_video = Embeds.create_video_embed(other_space, %{name: "Other Space Video"}) |> elem(1)

    {other_space, other_video}
  end

  defp authenticated_conn(conn, email) do
    session_token = session_token_for(email)
    init_test_session(conn, user_token: session_token)
  end

  defp session_token_for(email) do
    assert {:ok, user} = Accounts.create_user(email)
    login_token = Accounts.generate_user_login_token(user)
    assert {:ok, {logged_in_user, persisted_login_token}} = Accounts.login_user(login_token)

    Accounts.generate_user_session_token(persisted_login_token, logged_in_user)
  end

  defp with_maintenance(fun) do
    previous = Application.get_env(:mave_core, :maintenance_mode)
    Application.put_env(:mave_core, :maintenance_mode, true)

    try do
      fun.()
    after
      restore_env(:maintenance_mode, previous)
    end
  end

  defp with_flow_admin(email, fun) do
    previous = Application.get_env(:mave_core, :flow_admin)
    Application.put_env(:mave_core, :flow_admin, emails: [email], email_domains: [])

    try do
      fun.()
    after
      restore_env(:flow_admin, previous)
    end
  end

  defp restore_env(key, nil), do: Application.delete_env(:mave_core, key)
  defp restore_env(key, value), do: Application.put_env(:mave_core, key, value)

  defp with_host(conn, host), do: %{conn | host: host}

  defp with_env(name, value, fun) do
    previous = System.get_env(name)
    System.put_env(name, value)

    try do
      fun.()
    after
      if is_nil(previous), do: System.delete_env(name), else: System.put_env(name, previous)
    end
  end
end
