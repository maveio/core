defmodule MaveCoreWeb.EndpointConfigTest do
  use ExUnit.Case, async: true

  test "production force_ssl allows internal upload hooks over cluster HTTP" do
    prod_config = Config.Reader.read!("config/prod.exs", env: :prod)
    force_ssl = prod_config[:mave_core][MaveCoreWeb.Endpoint][:force_ssl]

    assert "/internal/upload-hooks/tusd" in force_ssl[:exclude][:paths]
  end

  test "health requests disable endpoint telemetry logging" do
    assert MaveCoreWeb.Endpoint.log_level(%Plug.Conn{request_path: "/health"}) == false
    assert MaveCoreWeb.Endpoint.log_level(%Plug.Conn{request_path: "/api/v1/videos"}) == :info
  end
end
