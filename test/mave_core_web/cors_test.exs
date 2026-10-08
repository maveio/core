defmodule MaveCoreWeb.CORSTest do
  use MaveCoreWeb.ConnCase, async: true

  alias MaveCore.{Accounts, Spaces}

  @untrusted_origin "https://untrusted.example"

  test "dashboard and flow administration never grant cross-origin cookie access", %{conn: conn} do
    for path <- ["/login", "/v1/flow/step-types"] do
      response = conn |> put_req_header("origin", @untrusted_origin) |> get(path)
      assert get_resp_header(response, "access-control-allow-origin") == []
      assert get_resp_header(response, "access-control-allow-credentials") == []
    end
  end

  test "internal upload hooks do not expose CORS headers", %{conn: conn} do
    response =
      conn
      |> put_req_header("origin", @untrusted_origin)
      |> post("/internal/upload-hooks/tusd", %{})

    assert get_resp_header(response, "access-control-allow-origin") == []
    assert get_resp_header(response, "access-control-allow-credentials") == []
  end

  test "public API calls accept explicit credentials without enabling cookie CORS", %{conn: conn} do
    {:ok, user} = Accounts.create_user("cors-#{System.unique_integer([:positive])}@example.com")
    {:ok, key} = Spaces.create_key(user.current_space_membership.space)

    response =
      conn
      |> put_req_header("origin", @untrusted_origin)
      |> put_req_header("authorization", "Bearer " <> Spaces.display_api_key(key.key, key.secret))
      |> get("/api/v1/videos")

    assert json_response(response, 200)
    assert get_resp_header(response, "access-control-allow-origin") == ["*"]
    assert get_resp_header(response, "access-control-allow-credentials") == []
  end

  test "public preflights work without authentication", %{conn: conn} do
    for path <- [
          "/api/v1/videos",
          "/v1/videos/example",
          "/api/v1/collections",
          "/v1/cli/authorizations",
          "/exampleposter"
        ] do
      response =
        conn
        |> put_req_header("origin", @untrusted_origin)
        |> put_req_header("access-control-request-method", "POST")
        |> put_req_header("access-control-request-headers", "authorization, content-type")
        |> options(path)

      assert response(response, 204) == ""
      assert get_resp_header(response, "access-control-allow-origin") == ["*"]
      assert get_resp_header(response, "access-control-allow-credentials") == []
      assert [headers] = get_resp_header(response, "access-control-allow-headers")
      assert headers =~ "authorization"
      refute headers =~ "x-csrf-token"
    end
  end
end
