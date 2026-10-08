defmodule MaveCoreWeb.Plugs.RequireHostTest do
  use ExUnit.Case, async: true

  import Plug.Conn
  import Plug.Test

  alias MaveCoreWeb.Plugs.RequireHost

  test "renders the styled not found page for browser host mismatches" do
    conn =
      :get
      |> conn("/videos")
      |> Map.put(:host, "wrong.example.com")
      |> put_req_header("accept", "text/html")
      |> RequireHost.call(RequireHost.init(hosts: ["manage.example.com"]))

    assert conn.halted
    assert conn.status == 404
    assert get_resp_header(conn, "content-type") == ["text/html; charset=utf-8"]
    assert conn.resp_body =~ "<title>Page not found</title>"
    assert conn.resp_body =~ "Page not found"
  end

  test "keeps the plain not found response for non-browser host mismatches" do
    conn =
      :get
      |> conn("/v1/videos")
      |> Map.put(:host, "wrong.example.com")
      |> put_req_header("accept", "application/json")
      |> RequireHost.call(RequireHost.init(hosts: ["api.example.com"]))

    assert conn.halted
    assert conn.status == 404
    assert get_resp_header(conn, "content-type") == ["text/plain; charset=utf-8"]
    assert conn.resp_body == "Not found"
  end
end
