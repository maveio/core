defmodule MaveCore.MCP.SDKInteropTest do
  use MaveCoreWeb.ConnCase, async: false
  import MaveCore.MCPFixtures

  test "the official MCP SDK initializes, discovers and calls tools over HTTP" do
    server = start_supervised!({Bandit, plug: MaveCoreWeb.Endpoint, ip: {127, 0, 0, 1}, port: 0})
    {:ok, {_ip, port}} = ThousandIsland.listener_info(server)
    url = "http://127.0.0.1:#{port}/mcp"
    previous = Application.get_env(:mave_core, :mcp)
    Application.put_env(:mave_core, :mcp, resource_url: url)

    on_exit(fn ->
      if previous,
        do: Application.put_env(:mave_core, :mcp, previous),
        else: Application.delete_env(:mave_core, :mcp)
    end)

    fixture = mcp_grant_fixture()

    {output, status} =
      System.cmd("node", ["examples/mcp-client/interop.mjs"],
        env: [{"MAVE_MCP_TEST_URL", url}, {"MAVE_MCP_TEST_TOKEN", fixture.tokens.access_token}],
        stderr_to_stdout: true
      )

    assert status == 0, output
    assert output =~ "MCP SDK interoperability passed"
  end
end
