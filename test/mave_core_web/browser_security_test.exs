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

  test "browser CSP allows private playback storage without allowing its scripts", %{conn: conn} do
    original_endpoint = Application.get_env(:mave_core, :playback_public_storage_endpoint)
    Application.put_env(:mave_core, :playback_public_storage_endpoint, "http://localhost:9010")
    on_exit(fn -> restore_env(:playback_public_storage_endpoint, original_endpoint) end)

    conn = get(conn, ~p"/health")
    assert [csp] = get_resp_header(conn, "content-security-policy")
    directives = String.split(csp, "; ")

    for name <- ["img-src", "media-src", "connect-src"] do
      directive = Enum.find(directives, &String.starts_with?(&1, name <> " "))
      assert "http://localhost:9010" in String.split(directive)
    end

    script_src = Enum.find(directives, &String.starts_with?(&1, "script-src "))
    refute "http://localhost:9010" in String.split(script_src)
  end

  test "browser CSP permits the configured local space media host" do
    previous = Application.get_env(:mave_core, :playback_origin)
    Application.put_env(:mave_core, :playback_origin, "http://signed.localhost:4001")
    on_exit(fn -> restore_env(:playback_origin, previous) end)
    directives = MaveCoreWeb.BrowserSecurity.content_security_policy() |> String.split("; ")

    for name <- ["img-src", "media-src", "connect-src"] do
      assert Enum.find(directives, &String.starts_with?(&1, name <> " ")) =~
               "http://*.signed.localhost:4001"
    end

    refute Enum.find(directives, &String.starts_with?(&1, "script-src ")) =~ "signed.localhost"
  end

  defp restore_env(key, nil), do: Application.delete_env(:mave_core, key)
  defp restore_env(key, value), do: Application.put_env(:mave_core, key, value)
end
