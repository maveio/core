defmodule MaveCore.InstallationConfigTest do
  use ExUnit.Case, async: true

  @moduletag :tmp_dir
  @init Path.expand("../../deploy/self-hosted/quickstart/init.sh", __DIR__)

  test "initialization generates persistent configuration without exposing it", %{tmp_dir: dir} do
    env = [{"MAVE_SETUP_DIR", dir}]
    assert {output, 0} = System.cmd("sh", [@init], env: env)
    config = File.read!(Path.join(dir, "environment.sh"))
    code = File.read!(Path.join(dir, "code")) |> String.trim()
    assert byte_size(code) == 48
    refute output =~ code
    assert config =~ "RELEASE_COOKIE"
    assert {_, 0} = System.cmd("sh", [@init], env: env)
    assert File.read!(Path.join(dir, "environment.sh")) == config
    assert String.trim(File.read!(Path.join(dir, "code"))) == code
  end

  test "generated defaults preserve explicit operator credentials", %{tmp_dir: dir} do
    assert {_, 0} = System.cmd("sh", [@init], env: [{"MAVE_SETUP_DIR", dir}])

    assert {"preserved", 0} =
             System.cmd(
               "sh",
               [
                 "-c",
                 ~s(. "$1"; printf '%s' "$POSTGRES_PASSWORD"),
                 "sh",
                 Path.join(dir, "environment.sh")
               ],
               env: [{"POSTGRES_PASSWORD", "preserved"}]
             )
  end
end
