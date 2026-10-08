defmodule MaveCoreWeb.Api.LegacyEmbedControllerTest do
  use MaveCoreWeb.ConnCase

  alias MaveCore.Accounts
  alias MaveCore.Assets.Video
  alias MaveCore.Embeds
  alias MaveCore.Embeds.SettingsSerializer
  alias MaveCore.PublicApi
  alias MaveCore.Repo
  alias MaveCore.Spaces
  alias MaveCore.TestSupport.FlowStorageAdapterStub

  setup do
    previous_storage_adapter = Application.get_env(:mave_core, :flow_storage_adapter)
    Application.put_env(:mave_core, :flow_storage_adapter, FlowStorageAdapterStub)
    FlowStorageAdapterStub.reset!()

    on_exit(fn ->
      FlowStorageAdapterStub.reset!()
      restore_env(:flow_storage_adapter, previous_storage_adapter)
    end)

    email = "api-legacy-embed-#{System.unique_integer([:positive])}@example.com"
    {:ok, user} = Accounts.create_user(email)
    space = user.current_space_membership.space
    {:ok, key} = Spaces.create_key(space)

    root_video = Embeds.create_video_embed(space, %{name: "Root Video"}) |> elem(1)
    folder = Embeds.create_folder_embed(space, %{name: "JWT Folder"}) |> elem(1)

    child_video =
      Embeds.create_video_embed(space, %{name: "Child Video", parent_folder_id: folder.id})
      |> elem(1)

    child_folder =
      Embeds.create_folder_embed(space, %{name: "Child Folder", parent_folder_id: folder.id})
      |> elem(1)

    nested_video =
      Embeds.create_video_embed(space, %{
        name: "Nested Video",
        parent_folder_id: child_folder.id
      })
      |> elem(1)

    root_video = attach_current_video(space, root_video)
    child_video = attach_current_video(space, child_video)
    nested_video = attach_current_video(space, nested_video)

    %{
      key: key,
      space: space,
      root_video: root_video,
      folder: folder,
      child_video: child_video,
      child_folder: child_folder,
      nested_video: nested_video
    }
  end

  test "GET /api/v1/:embed_id returns the current manifest shape", %{
    conn: conn,
    space: space,
    root_video: root_video
  } do
    embed_id = space.hash <> root_video.hash

    conn = get(conn, ~p"/api/v1/#{embed_id}")

    assert %{
             "id" => ^embed_id,
             "name" => "Root Video",
             "space_id" => space_hash,
             "created_at" => created_at,
             "video" => video,
             "settings" => settings,
             "poster" => poster,
             "subtitles" => [],
             "audio_tracks" => []
           } = json_response(conn, 200)

    assert space_hash == space.hash
    assert is_integer(created_at)
    assert settings["controls"] == "full"

    assert poster["image_src"] ==
             SettingsSerializer.storage_object_url(
               "space-#{space.hash}",
               "#{root_video.hash}/thumbnail.jpg"
             )

    assert video["filetype"] == "mp4"
    assert video["status"] == "ready"
    assert video["ready"] == true
  end

  test "GET /v1/:embed_id works on the configured API host", %{
    conn: conn,
    space: space,
    root_video: root_video
  } do
    embed_id = space.hash <> root_video.hash

    with_env("MAVE_API_HOST", "api.mave.io", fn ->
      conn =
        conn
        |> with_host("api.mave.io")
        |> get(~p"/v1/#{embed_id}")

      assert %{"id" => ^embed_id, "video" => %{"status" => "ready"}} =
               json_response(conn, 200)
    end)
  end

  test "GET /v1/:embed_id is not exposed on non-API hosts", %{
    conn: conn,
    space: space,
    root_video: root_video
  } do
    embed_id = space.hash <> root_video.hash

    with_env("MAVE_API_HOST", "api.mave.io", fn ->
      conn =
        conn
        |> with_host("dash.mave.io")
        |> get(~p"/v1/#{embed_id}")

      assert response(conn, 404) == "Not found"
    end)
  end

  test "GET /api/v1/:embed_id returns 404 for unknown embeds", %{conn: conn, space: space} do
    embed_id = space.hash <> "AAAAAAAAAA"

    conn = get(conn, ~p"/api/v1/#{embed_id}")

    assert %{"error" => "This video embed does not exist."} = json_response(conn, 404)
  end

  test "GET /api/v1/collection/:token returns root videos and collections", %{
    conn: conn,
    key: key,
    space: space,
    root_video: root_video,
    folder: folder,
    child_video: child_video
  } do
    token = sign_jwt(key, %{"sub" => space.id})

    conn = get(conn, ~p"/api/v1/collection/#{token}")

    assert %{
             "name" => "",
             "metrics_key" => nil,
             "videos" => videos,
             "collections" => collections,
             "embeds" => embeds
           } = json_response(conn, 200)

    assert Enum.map(videos, & &1["id"]) == ["#{space.hash}#{root_video.hash}"]
    assert Enum.map(collections, & &1["id"]) == ["#{space.hash}#{folder.hash}"]
    assert Enum.map(embeds, & &1["id"]) == ["#{space.hash}#{root_video.hash}"]
    refute Enum.any?(videos, &(&1["id"] == "#{space.hash}#{child_video.hash}"))
  end

  test "GET /api/v1/collection/:token accepts collection claim", %{
    conn: conn,
    key: key,
    space: space,
    folder: folder,
    child_video: child_video,
    child_folder: child_folder
  } do
    token = sign_jwt(key, %{"sub" => space.id, "collection" => "#{space.hash}#{folder.hash}"})

    conn = get(conn, ~p"/api/v1/collection/#{token}")

    assert %{"name" => "JWT Folder", "videos" => videos, "collections" => collections} =
             json_response(conn, 200)

    assert Enum.map(videos, & &1["id"]) == ["#{space.hash}#{child_video.hash}"]
    assert Enum.map(collections, & &1["id"]) == ["#{space.hash}#{child_folder.hash}"]
  end

  test "GET /api/v1/collection/:token accepts nested embed param", %{
    conn: conn,
    key: key,
    space: space,
    folder: folder,
    child_folder: child_folder,
    nested_video: nested_video
  } do
    token = sign_jwt(key, %{"sub" => space.id, "collection" => "#{space.hash}#{folder.hash}"})

    conn = get(conn, ~p"/api/v1/collection/#{token}?embed=#{space.hash <> child_folder.hash}")

    assert %{"name" => "Child Folder", "videos" => videos, "collections" => []} =
             json_response(conn, 200)

    assert Enum.map(videos, & &1["id"]) == ["#{space.hash}#{nested_video.hash}"]
  end

  test "GET /api/v1/collection/:token rejects invalid token", %{conn: conn} do
    conn = get(conn, ~p"/api/v1/collection/not-a-valid-token")

    assert %{"error" => "Invalid JWT or collection id (either invalid sub or API key)"} =
             json_response(conn, 400)
  end

  test "DELETE /api/v1/videos/:embed_hash/:token deletes scoped video when can_delete is true", %{
    conn: conn,
    key: key,
    space: space,
    folder: folder,
    child_video: child_video
  } do
    token =
      sign_jwt(key, %{
        "sub" => space.id,
        "collection" => "#{space.hash}#{folder.hash}",
        "can_delete" => true
      })

    conn = delete(conn, ~p"/api/v1/videos/#{child_video.hash}/#{token}")

    assert %{"id" => id, "object" => "video"} = json_response(conn, 200)
    assert id == "#{space.hash}#{child_video.hash}"

    assert is_nil(PublicApi.get_embed(space, child_video.hash))
  end

  test "read-only signing keys keep collection reads working but reject deletes", %{
    conn: conn,
    key: key,
    space: space,
    folder: folder,
    child_video: child_video
  } do
    token =
      sign_jwt(key, %{
        "sub" => space.id,
        "collection" => "#{space.hash}#{folder.hash}",
        "can_delete" => true
      })

    assert {:ok, _key} = Spaces.make_key_read_only(key)

    read_conn = get(conn, ~p"/api/v1/collection/#{token}")
    assert %{"name" => "JWT Folder"} = json_response(read_conn, 200)

    delete_conn =
      delete(build_conn(), ~p"/api/v1/videos/#{child_video.hash}/#{token}")

    assert %{"error" => "Invalid JWT or collection id (either invalid sub or API key)"} =
             json_response(delete_conn, 400)

    refute is_nil(PublicApi.get_embed(space, child_video.hash))
  end

  test "DELETE /api/v1/videos/:embed_hash/:token rejects missing can_delete and out-of-scope videos",
       %{
         conn: conn,
         key: key,
         space: space,
         root_video: root_video,
         folder: folder,
         child_video: child_video
       } do
    read_only_token =
      sign_jwt(key, %{"sub" => space.id, "collection" => "#{space.hash}#{folder.hash}"})

    conn = delete(conn, ~p"/api/v1/videos/#{child_video.hash}/#{read_only_token}")

    assert %{"error" => "Invalid JWT or collection id (either invalid sub or API key)"} =
             json_response(conn, 400)

    delete_token =
      sign_jwt(key, %{
        "sub" => space.id,
        "collection" => "#{space.hash}#{folder.hash}",
        "can_delete" => true
      })

    conn = delete(build_conn(), ~p"/api/v1/videos/#{root_video.hash}/#{delete_token}")

    assert %{"error" => "Could not delete video"} = json_response(conn, 400)
    refute is_nil(PublicApi.get_embed(space, root_video.hash))
  end

  defp attach_current_video(space, embed) do
    current_video =
      %Video{}
      |> Video.changeset(%{
        asset_id: embed.asset_id,
        status: "ready",
        file_name: "#{embed.hash}.mp4"
      })
      |> Repo.insert!()

    embed.asset
    |> Ecto.Changeset.change(current_video_id: current_video.id)
    |> Repo.update!()

    PublicApi.get_embed(space, embed.hash)
  end

  defp sign_jwt(key, claims) do
    header = %{"alg" => "HS256", "typ" => "JWT"} |> Jason.encode!() |> base64url()
    payload = claims |> Jason.encode!() |> base64url()
    signing_input = "#{header}.#{payload}"

    signature =
      :crypto.mac(:hmac, :sha256, Spaces.display_api_key(key.key, key.secret), signing_input)
      |> base64url()

    "#{signing_input}.#{signature}"
  end

  defp base64url(value), do: Base.url_encode64(value, padding: false)

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
