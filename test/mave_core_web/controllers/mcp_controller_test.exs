defmodule MaveCoreWeb.McpControllerTest do
  use MaveCoreWeb.ConnCase, async: true
  import MaveCore.MCPFixtures
  alias MaveCore.MCP.{Config, OAuth}

  test "unauthenticated clients discover the OAuth server", %{conn: conn} do
    conn = post(conn, "/mcp", %{})
    assert json_response(conn, 401)["error"] == "invalid_token"

    assert hd(get_resp_header(conn, "www-authenticate")) =~
             "/.well-known/oauth-protected-resource/mcp"

    metadata =
      build_conn() |> get("/.well-known/oauth-protected-resource/mcp") |> json_response(200)

    assert metadata["resource"] == Config.resource_url()

    metadata =
      build_conn() |> get("/.well-known/oauth-authorization-server") |> json_response(200)

    assert metadata["code_challenge_methods_supported"] == ["S256"]
    assert metadata["authorization_endpoint"] == Config.authorization_url()
  end

  test "registration and form-encoded token exchange work over HTTP" do
    conn =
      post(build_conn(), "/oauth/mcp/register", %{
        "client_name" => "HTTP client",
        "redirect_uris" => ["https://client.example/callback"]
      })

    assert json_response(conn, 201)["client_id"]
    assert get_resp_header(conn, "cache-control") == ["no-store"]
    f = mcp_code_fixture()

    conn =
      build_conn()
      |> put_req_header("content-type", "application/x-www-form-urlencoded")
      |> post("/oauth/mcp/token", URI.encode_query(f.exchange))

    assert %{"access_token" => access, "refresh_token" => refresh} = json_response(conn, 200)
    assert {:ok, _} = OAuth.authenticate(access)

    conn =
      post(build_conn(), "/oauth/mcp/revoke", %{"client_id" => f.client.id, "token" => refresh})

    assert response(conn, 200) == ""
    assert {:error, :invalid_token} = OAuth.authenticate(access)
  end

  test "initialize, tools/list, ping and notifications use stateless JSON responses" do
    f = mcp_grant_fixture()

    result =
      rpc(f, "initialize", %{
        "protocolVersion" => "2025-11-25",
        "capabilities" => %{},
        "clientInfo" => %{}
      })

    assert result["result"]["protocolVersion"] == "2025-11-25"
    assert result["result"]["capabilities"]["tools"] == %{"listChanged" => false}
    assert rpc(f, "ping")["result"] == %{}
    names = rpc(f, "tools/list")["result"]["tools"] |> Enum.map(& &1["name"])
    assert "mave_list_videos" in names
    refute "mave_delete_video" in names
    conn = request(f, %{"jsonrpc" => "2.0", "method" => "notifications/initialized"})
    assert response(conn, 202) == ""
    assert get_resp_header(conn, "mcp-session-id") == []
  end

  test "read-only access rejects writes even if the caller knows the tool name" do
    f = mcp_grant_fixture()

    assert rpc(f, "tools/call", %{"name" => "mave_create_video", "arguments" => %{}})["error"][
             "code"
           ] == -32_602

    assert MaveCore.PublicApi.count_videos(f.space) == 0
  end

  test "video and collection tools create, list, update, move and delete" do
    f = mcp_grant_fixture(scope: "mave:read mave:write")
    collection = call(f, "mave_create_collection", %{"name" => "Launch"})
    video = call(f, "mave_create_video", %{"name" => "Demo", "collection" => collection["id"]})
    assert call(f, "mave_get_video", %{"id" => video["id"]})["name"] == "Demo"
    assert call(f, "mave_list_videos", %{"collection" => collection["id"]})["total_items"] == 1
    assert call(f, "mave_list_collections", %{})["total_items"] == 1

    assert call(f, "mave_update_video", %{
             "id" => video["id"],
             "name" => "New name",
             "collection" => nil
           })["name"] == "New name"

    assert call(f, "mave_update_collection", %{"id" => collection["id"], "name" => "Renamed"})[
             "name"
           ] == "Renamed"

    result =
      rpc(f, "tools/call", %{
        "name" => "mave_delete_video",
        "arguments" => %{"id" => video["id"], "confirm" => false}
      })

    assert result["error"]["code"] == -32_602
    assert call(f, "mave_delete_video", %{"id" => video["id"], "confirm" => true})["deleted"]

    assert call(f, "mave_delete_collection", %{"id" => collection["id"], "confirm" => true})[
             "deleted"
           ]
  end

  test "tools cannot read, modify, delete or move to another space's items" do
    f = mcp_grant_fixture(scope: "mave:read mave:write")
    other = mcp_grant_fixture(scope: "mave:read mave:write")
    video = call(other, "mave_create_video", %{})
    folder = call(other, "mave_create_collection", %{"name" => "Private"})

    for {name, args} <- [
          {"mave_get_video", %{"id" => video["id"]}},
          {"mave_update_video", %{"id" => video["id"], "name" => "Attack"}},
          {"mave_delete_video", %{"id" => video["id"], "confirm" => true}},
          {"mave_create_video", %{"collection" => folder["id"]}}
        ] do
      assert rpc(f, "tools/call", %{"name" => name, "arguments" => args})["result"]["isError"]
    end

    assert call(other, "mave_get_video", %{"id" => video["id"]})["id"] == video["id"]
  end

  test "invalid arguments and methods produce protocol errors without mutations" do
    f = mcp_grant_fixture(scope: "mave:read mave:write")

    for args <- [
          %{"page" => 0},
          %{"per_page" => 101},
          %{"page" => "1"},
          %{"api_url" => "https://evil.example"}
        ] do
      assert rpc(f, "tools/call", %{"name" => "mave_list_videos", "arguments" => args})["error"][
               "code"
             ] == -32_602
    end

    assert rpc(f, "unknown")["error"]["code"] == -32_601

    assert request(f, [%{"jsonrpc" => "2.0", "id" => 1, "method" => "ping"}])
           |> json_response(200)
           |> get_in(["error", "code"]) == -32_600
  end

  test "origin, media type, version and method checks protect the transport" do
    f = mcp_grant_fixture()
    conn = auth_conn(f) |> put_req_header("origin", "https://evil.example") |> post("/mcp", "{}")
    assert response(conn, 403) == "Origin not allowed"
    conn = auth_conn(f) |> put_req_header("mcp-protocol-version", "bad") |> post("/mcp", "{}")
    assert json_response(conn, 400)["error"]
    conn = auth_conn(f) |> put_req_header("accept", "application/json") |> post("/mcp", "{}")
    assert json_response(conn, 406)["error"]
    conn = auth_conn(f) |> put_req_header("content-type", "text/plain") |> post("/mcp", "{}")
    assert json_response(conn, 415)["error"]
    conn = auth_conn(f) |> get("/mcp")
    assert response(conn, 405) == ""
  end

  defp rpc(f, method, params \\ %{}),
    do:
      request(f, %{"jsonrpc" => "2.0", "id" => 1, "method" => method, "params" => params})
      |> json_response(200)

  defp request(f, message), do: auth_conn(f) |> post("/mcp", Jason.encode!(message))

  defp auth_conn(f),
    do:
      build_conn()
      |> put_req_header("authorization", "Bearer " <> f.tokens.access_token)
      |> put_req_header("content-type", "application/json")
      |> put_req_header("accept", "application/json, text/event-stream")

  defp call(f, name, args),
    do:
      rpc(f, "tools/call", %{"name" => name, "arguments" => args})["result"]["structuredContent"]
end
