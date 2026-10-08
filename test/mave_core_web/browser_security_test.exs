defmodule MaveCoreWeb.BrowserSecurityTest do
  use MaveCoreWeb.ConnCase

  test "health route disables Phoenix request logging" do
    assert %{log: false} =
             Phoenix.Router.route_info(
               MaveCoreWeb.Router,
               "GET",
               "/health",
               "dash.staging.mave.io"
             )
  end

  test "browser CSP allows the default components CDN", %{conn: conn} do
    conn = get(conn, ~p"/health")

    assert [csp] = get_resp_header(conn, "content-security-policy")
    assert csp =~ "script-src"
    assert csp =~ "https://cdn.video-dns.com"
  end

  test "browser CSP allows the runtime-configured components origin", %{conn: conn} do
    original_base_url = Application.get_env(:mave_core, :components_base_url)

    Application.put_env(
      :mave_core,
      :components_base_url,
      "https://components.saas.orb.local"
    )

    on_exit(fn -> restore_env(:components_base_url, original_base_url) end)

    conn = get(conn, ~p"/health")

    assert [csp] = get_resp_header(conn, "content-security-policy")
    assert csp =~ "script-src"
    assert csp =~ "https://components.saas.orb.local"
  end

  test "browser CSP allows explicit self-hosted storage and upload origins", %{conn: conn} do
    original_cdn_base_url = Application.get_env(:mave_core, :public_cdn_base_url)
    original_upload = Application.get_env(:mave_core, :upload)

    Application.put_env(:mave_core, :public_cdn_base_url, "http://localhost:9000")
    Application.put_env(:mave_core, :upload, endpoint: "http://localhost:1080/files")

    on_exit(fn ->
      restore_env(:public_cdn_base_url, original_cdn_base_url)
      restore_env(:upload, original_upload)
    end)

    conn = get(conn, ~p"/health")

    assert [csp] = get_resp_header(conn, "content-security-policy")
    assert csp =~ "http://localhost:9000"
    assert csp =~ "http://localhost:1080"
  end

  defp restore_env(key, nil), do: Application.delete_env(:mave_core, key)
  defp restore_env(key, value), do: Application.put_env(:mave_core, key, value)
end
