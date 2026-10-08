defmodule MaveCore.ReleaseEnvTest do
  use ExUnit.Case, async: true

  @env_script Path.expand("../../rel/env.sh.eex", __DIR__)
  @cookie String.duplicate("a", 32)

  for command <- ~w(start start_iex daemon daemon_iex remote rpc restart stop pid) do
    test "#{command} refuses a missing or short cookie" do
      assert {output, 1} = source(unquote(command), nil)
      assert output =~ "RELEASE_COOKIE must be a secret of at least 32 characters"
      assert {_output, 1} = source(unquote(command), String.duplicate("a", 31))
      assert {"", 0} = source(unquote(command), @cookie)
    end
  end

  test "commands without distribution do not need a cookie" do
    assert {"", 0} = source("eval", nil)
    assert {"", 0} = source("version", nil)
  end

  defp source(command, cookie) do
    System.cmd("sh", ["-c", ~s(. "$0"), @env_script],
      env: [{"RELEASE_COMMAND", command}, {"RELEASE_COOKIE", cookie}],
      stderr_to_stdout: true
    )
  end
end
