defmodule MaveCoreWeb.Api.SearchControllerTest do
  use MaveCoreWeb.ConnCase

  alias MaveCore.Accounts
  alias MaveCore.Assets.{Asset, Video}
  alias MaveCore.Embeds
  alias MaveCore.Repo
  alias MaveCore.Search
  alias MaveCore.Spaces

  setup do
    email = "api-search-#{System.unique_integer([:positive])}@example.com"
    {:ok, user} = Accounts.create_user(email)
    space = user.current_space_membership.space
    {:ok, key} = Spaces.create_key(space)

    {:ok, folder} = Embeds.create_folder_embed(space, %{name: "Courses"})

    {:ok, nested} =
      Embeds.create_folder_embed(space, %{name: "Baking", parent_folder_id: folder.id})

    root_video = video(space, "Harbour tour", nil, "A woman rides a red bicycle past the boats.")
    course_video = video(space, "Bike repair", nested.id, "Hands oil the chain of a red bicycle.")

    auth = "Bearer " <> Spaces.display_api_key(key.key, key.secret)

    %{
      space: space,
      key: key,
      auth: auth,
      folder: folder,
      root_video: root_video,
      course_video: course_video
    }
  end

  test "GET /api/v1/search returns matching videos with their moments", %{
    conn: conn,
    auth: auth,
    space: space,
    root_video: root_video,
    course_video: course_video
  } do
    conn = conn |> put_req_header("authorization", auth) |> get(~p"/api/v1/search?q=red+bicy")

    assert %{"object" => "list", "query" => "red bicy", "data" => results} =
             json_response(conn, 200)

    assert Enum.sort(Enum.map(results, & &1["id"])) ==
             Enum.sort(["#{space.hash}#{root_video.hash}", "#{space.hash}#{course_video.hash}"])

    result = Enum.find(results, &(&1["name"] == "Harbour tour"))

    assert %{
             "object" => "search_result",
             "matched_on" => ["visual"],
             "moments" => [
               %{
                 "source" => "visual",
                 "start" => 12.0,
                 "end" => 15.0,
                 "text" => "A woman rides a red bicycle past the boats.",
                 "snippet" => snippet
               }
             ]
           } = result

    assert %{"text" => "bicycle", "match" => true} in snippet
    assert %{"text" => "A woman rides a ", "match" => false} in snippet
  end

  test "GET /api/v1/search can be limited to a collection, including nested ones", %{
    conn: conn,
    auth: auth,
    space: space,
    folder: folder,
    course_video: course_video
  } do
    conn =
      conn
      |> put_req_header("authorization", auth)
      |> get(~p"/api/v1/search?q=bicycle&collection=#{space.hash <> folder.hash}")

    assert %{"data" => [%{"id" => id}]} = json_response(conn, 200)
    assert id == "#{space.hash}#{course_video.hash}"

    other_space_conn =
      build_conn()
      |> put_req_header("authorization", auth)
      |> get(~p"/api/v1/search?q=bicycle&collection=nope")

    assert %{"error" => "This collection does not seem to be part of your space."} =
             json_response(other_space_conn, 400)
  end

  test "GET /api/v1/search needs a key and a query, and never crosses spaces", %{
    conn: conn,
    auth: auth
  } do
    assert json_response(get(conn, ~p"/api/v1/search?q=bicycle"), 401)

    missing = build_conn() |> put_req_header("authorization", auth) |> get(~p"/api/v1/search")
    assert %{"error" => "Missing search query (q)."} = json_response(missing, 400)

    {:ok, other_user} =
      Accounts.create_user("api-search-other-#{System.unique_integer()}@example.com")

    other_space = other_user.current_space_membership.space
    {:ok, other_key} = Spaces.create_key(other_space)
    other_auth = "Bearer " <> Spaces.display_api_key(other_key.key, other_key.secret)

    other =
      build_conn()
      |> put_req_header("authorization", other_auth)
      |> get(~p"/api/v1/search?q=bicycle")

    assert %{"data" => []} = json_response(other, 200)
  end

  test "GET /api/v1/collection/:token/search is limited to the token's scope", %{
    conn: conn,
    key: key,
    space: space,
    folder: folder,
    course_video: course_video
  } do
    library = sign_jwt(key, %{"sub" => space.id})
    conn = get(conn, ~p"/api/v1/collection/#{library}/search?q=bicycle")
    assert %{"data" => [_, _]} = json_response(conn, 200)

    scoped = sign_jwt(key, %{"sub" => space.id, "collection" => "#{space.hash}#{folder.hash}"})
    conn = get(build_conn(), ~p"/api/v1/collection/#{scoped}/search?q=bicycle&limit=5")

    assert %{"data" => [%{"id" => id, "moments" => [%{"start" => 12.0}]}]} =
             json_response(conn, 200)

    assert id == "#{space.hash}#{course_video.hash}"

    conn = get(build_conn(), ~p"/api/v1/collection/not-a-valid-token/search?q=bicycle")

    assert %{"error" => "Invalid JWT or collection id (either invalid sub or API key)"} =
             json_response(conn, 400)
  end

  defp video(space, name, parent_folder_id, visual_text) do
    {:ok, embed} =
      Embeds.create_video_embed(space, %{name: name, parent_folder_id: parent_folder_id})

    video = Repo.insert!(%Video{asset_id: embed.asset_id, status: "ready", duration: 60.0})

    Asset
    |> Repo.get!(embed.asset_id)
    |> Ecto.Changeset.change(current_video_id: video.id)
    |> Repo.update!()

    {:ok, 1} =
      Search.index_video(video, space.id, [
        %{source: "visual", start: 12.0, end: 15.0, text: visual_text}
      ])

    embed
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
end
