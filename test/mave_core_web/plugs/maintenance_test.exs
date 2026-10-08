defmodule MaveCoreWeb.Plugs.MaintenanceTest do
  use ExUnit.Case, async: false

  import Plug.Conn
  import Plug.Test

  alias MaveCoreWeb.Plugs.Maintenance

  setup do
    previous_core = Application.get_env(:mave_core, :maintenance_mode)
    previous_saas = Application.get_env(:mave_saas, :maintenance_mode)
    previous_flow_admin = Application.get_env(:mave_core, :flow_admin)
    previous_env = System.get_env("MAVE_MAINTENANCE")
    previous_file = System.get_env("MAVE_MAINTENANCE_FILE")
    previous_image_host = System.get_env("MAVE_IMAGE_HOST")

    Application.delete_env(:mave_core, :maintenance_mode)
    Application.delete_env(:mave_saas, :maintenance_mode)
    Application.delete_env(:mave_core, :flow_admin)
    System.delete_env("MAVE_MAINTENANCE")
    System.delete_env("MAVE_MAINTENANCE_FILE")
    System.delete_env("MAVE_IMAGE_HOST")

    on_exit(fn ->
      restore_app_env(:mave_core, :maintenance_mode, previous_core)
      restore_app_env(:mave_saas, :maintenance_mode, previous_saas)
      restore_app_env(:mave_core, :flow_admin, previous_flow_admin)
      restore_env("MAVE_MAINTENANCE", previous_env)
      restore_env("MAVE_MAINTENANCE_FILE", previous_file)
      restore_env("MAVE_IMAGE_HOST", previous_image_host)
    end)
  end

  test "passes through when maintenance is disabled" do
    conn =
      :get
      |> conn("/videos")
      |> Maintenance.call(Maintenance.init([]))

    refute conn.halted
    refute conn.status
  end

  test "blocks html requests when maintenance is enabled" do
    Application.put_env(:mave_core, :maintenance_mode, true)

    conn =
      :get
      |> conn("/videos")
      |> put_req_header("accept", "text/html")
      |> Maintenance.call(Maintenance.init([]))

    assert conn.halted
    assert conn.status == 503
    assert get_resp_header(conn, "cache-control") == ["no-store"]
    assert get_resp_header(conn, "retry-after") == ["300"]
    assert conn.resp_body =~ "Temporarily unavailable"
  end

  test "blocks api requests with json when maintenance is enabled" do
    Application.put_env(:mave_core, :maintenance_mode, true)

    conn =
      :post
      |> conn("/api/v1/videos")
      |> put_req_header("accept", "application/json")
      |> Maintenance.call(Maintenance.init([]))

    assert conn.halted
    assert conn.status == 503
    assert Phoenix.json_library().decode!(conn.resp_body)["error"] == "maintenance"
  end

  test "allows configured paths during maintenance" do
    Application.put_env(:mave_saas, :maintenance_mode, true)

    conn =
      :post
      |> conn("/internal/webhooks/mollie")
      |> Maintenance.call(
        Maintenance.init(otp_app: :mave_saas, allowed_paths: ["/internal/webhooks/mollie"])
      )

    refute conn.halted
    refute conn.status
  end

  test "does not grant an implicit bypass to a hosted-service email domain" do
    Application.put_env(:mave_core, :maintenance_mode, true)

    conn =
      :get
      |> conn("/videos")
      |> Plug.Conn.assign(:current_user, %{email: "admin@mave.io"})
      |> Maintenance.call(Maintenance.init(allow_internal_users: true))

    assert conn.halted
    assert conn.status == 503
  end

  test "allows configured flow admins as internal users when configured" do
    Application.put_env(:mave_core, :maintenance_mode, true)
    Application.put_env(:mave_core, :flow_admin, emails: ["ops@example.com"], email_domains: [])

    conn =
      :get
      |> conn("/videos")
      |> Plug.Conn.assign(:current_user, %{email: "ops@example.com"})
      |> Maintenance.call(Maintenance.init(allow_internal_users: true))

    refute conn.halted
    refute conn.status
  end

  test "allows configured flow admin domains as internal users when configured" do
    Application.put_env(:mave_core, :maintenance_mode, true)
    Application.put_env(:mave_core, :flow_admin, emails: [], email_domains: ["admin.example.com"])

    conn =
      :get
      |> conn("/videos")
      |> Plug.Conn.assign(:current_user, %{email: "ops@admin.example.com"})
      |> Maintenance.call(Maintenance.init(allow_internal_users: true))

    refute conn.halted
    refute conn.status
  end

  test "blocks non-internal users when internal bypass is configured" do
    Application.put_env(:mave_core, :maintenance_mode, true)

    conn =
      :get
      |> conn("/videos")
      |> Plug.Conn.assign(:current_user, %{email: "customer@example.com"})
      |> Maintenance.call(Maintenance.init(allow_internal_users: true))

    assert conn.halted
    assert conn.status == 503
  end

  test "allows configured path prefixes during maintenance" do
    Application.put_env(:mave_core, :maintenance_mode, true)

    conn =
      :get
      |> conn("/auth/google")
      |> Maintenance.call(Maintenance.init(allowed_path_prefixes: ["/auth/"]))

    refute conn.halted
    refute conn.status
  end

  test "allows configured hosts during maintenance" do
    Application.put_env(:mave_core, :maintenance_mode, true)

    conn =
      :get
      |> conn("/ubg50XiyviR3oEq.webp?time=0")
      |> Map.put(:host, "image.mave.io")
      |> Maintenance.call(Maintenance.init(allowed_hosts: ["image.mave.io"]))

    refute conn.halted
    refute conn.status
  end

  test "allows hosts from configured environment variables during maintenance" do
    Application.put_env(:mave_core, :maintenance_mode, true)
    System.put_env("MAVE_IMAGE_HOST", "image.mave.io,image.video-dns.com")

    conn =
      :get
      |> conn("/ubg50XiyviR3oEq.webp?time=0")
      |> Map.put(:host, "image.video-dns.com")
      |> Maintenance.call(Maintenance.init(allowed_host_env_vars: ["MAVE_IMAGE_HOST"]))

    refute conn.halted
    refute conn.status
  end

  test "can be enabled by environment variable" do
    System.put_env("MAVE_MAINTENANCE", "1")

    assert Maintenance.enabled?()
  end

  test "can be enabled by file switch" do
    path = Path.join(System.tmp_dir!(), "mave-maintenance-#{System.unique_integer([:positive])}")
    File.write!(path, "")

    on_exit(fn -> File.rm(path) end)

    System.put_env("MAVE_MAINTENANCE_FILE", path)

    assert Maintenance.enabled?()
  end

  defp restore_app_env(otp_app, key, nil), do: Application.delete_env(otp_app, key)
  defp restore_app_env(otp_app, key, value), do: Application.put_env(otp_app, key, value)

  defp restore_env(key, nil), do: System.delete_env(key)
  defp restore_env(key, value), do: System.put_env(key, value)
end
