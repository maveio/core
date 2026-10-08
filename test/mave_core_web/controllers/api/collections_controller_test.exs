defmodule MaveCoreWeb.Api.CollectionsControllerTest do
  use MaveCoreWeb.ConnCase

  alias MaveCore.Accounts
  alias MaveCore.Embeds
  alias MaveCore.Spaces

  setup do
    email = "api-collections-#{System.unique_integer([:positive])}@example.com"
    {:ok, user} = Accounts.create_user(email)
    space = user.current_space_membership.space
    {:ok, key} = Spaces.create_key(space)
    folder = Embeds.create_folder_embed(space, %{name: "API Folder"}) |> elem(1)

    child_video =
      Embeds.create_video_embed(space, %{name: "Child Video", parent_folder_id: folder.id})
      |> elem(1)

    auth =
      key
      |> then(&Spaces.display_api_key(&1.key, &1.secret))
      |> then(&"Bearer #{&1}")

    %{space: space, auth: auth, folder: folder, child_video: child_video, key: key}
  end

  test "GET /api/v1/collections returns old collection response shape", %{
    conn: conn,
    auth: auth,
    space: space,
    folder: folder
  } do
    conn =
      conn
      |> put_req_header("authorization", auth)
      |> get(~p"/api/v1/collections")

    assert %{"object" => "list", "data" => [collection]} = json_response(conn, 200)
    assert collection["id"] == "#{space.hash}#{folder.hash}"
    assert collection["name"] == "API Folder"
    assert collection["object"] == "collection"
    assert collection["video_count"] == 1
  end

  test "GET /api/v1/collections accepts a public parent collection id filter", %{
    conn: conn,
    auth: auth,
    space: space,
    folder: folder
  } do
    child_folder =
      Embeds.create_folder_embed(space, %{name: "Child Folder", parent_folder_id: folder.id})
      |> elem(1)

    conn =
      conn
      |> put_req_header("authorization", auth)
      |> get(~p"/api/v1/collections?collection=#{space.hash <> folder.hash}")

    assert %{"data" => [collection], "total_items" => 1} = json_response(conn, 200)
    assert collection["id"] == "#{space.hash}#{child_folder.hash}"
  end

  test "read-only API keys reject collection mutations", %{
    conn: conn,
    auth: auth,
    key: key,
    folder: folder
  } do
    assert {:ok, _key} = Spaces.make_key_read_only(key)

    create_conn =
      conn
      |> put_req_header("authorization", auth)
      |> post(~p"/api/v1/collections", %{"name" => "Blocked Collection"})

    assert %{"error" => "This API key is read-only"} = json_response(create_conn, 403)

    update_conn =
      build_conn()
      |> put_req_header("authorization", auth)
      |> put(~p"/api/v1/collections/#{folder.hash}", %{"name" => "Blocked Rename"})

    assert %{"error" => "This API key is read-only"} = json_response(update_conn, 403)

    delete_conn =
      build_conn()
      |> put_req_header("authorization", auth)
      |> delete(~p"/api/v1/collections/#{folder.hash}")

    assert %{"error" => "This API key is read-only"} = json_response(delete_conn, 403)
  end

  test "POST /api/v1/collections creates collection", %{conn: conn, auth: auth, space: space} do
    conn =
      conn
      |> put_req_header("authorization", auth)
      |> post(~p"/api/v1/collections", %{"name" => "New API Folder"})

    assert %{"id" => id, "name" => "New API Folder", "object" => "collection"} =
             json_response(conn, 200)

    assert String.starts_with?(id, space.hash)
  end

  test "POST /api/v1/collections accepts a public parent collection id", %{
    conn: conn,
    auth: auth,
    space: space,
    folder: folder
  } do
    conn =
      conn
      |> put_req_header("authorization", auth)
      |> post(~p"/api/v1/collections", %{
        "name" => "Nested API Folder",
        "collection" => space.hash <> folder.hash
      })

    assert %{"id" => id, "name" => "Nested API Folder"} = json_response(conn, 200)
    assert String.starts_with?(id, space.hash)
  end

  test "PUT /api/v1/collections/:hash renames collection", %{
    conn: conn,
    auth: auth,
    folder: folder
  } do
    conn =
      conn
      |> put_req_header("authorization", auth)
      |> put(~p"/api/v1/collections/#{folder.hash}", %{"name" => "Renamed Folder"})

    assert %{"name" => "Renamed Folder"} = json_response(conn, 200)
  end

  test "PUT /api/v1/collections/:hash accepts the public id returned by the list endpoint", %{
    conn: conn,
    auth: auth,
    space: space,
    folder: folder
  } do
    conn =
      conn
      |> put_req_header("authorization", auth)
      |> put(~p"/api/v1/collections/#{space.hash <> folder.hash}", %{
        "name" => "Renamed Via Public ID"
      })

    assert %{"name" => "Renamed Via Public ID"} = json_response(conn, 200)
  end

  test "DELETE /api/v1/collections/:hash returns deleted collection payload", %{
    conn: conn,
    auth: auth,
    folder: folder
  } do
    conn =
      conn
      |> put_req_header("authorization", auth)
      |> delete(~p"/api/v1/collections/#{folder.hash}")

    assert %{"name" => "API Folder", "object" => "collection"} = json_response(conn, 200)
  end
end
