defmodule MaveCore.SelfHostedInstallerTest do
  use ExUnit.Case, async: true

  @moduletag :tmp_dir
  @root Path.expand("../..", __DIR__)

  setup %{tmp_dir: tmp_dir} do
    bin = Path.join(tmp_dir, "bin")
    File.mkdir_p!(bin)

    installer = Path.join(tmp_dir, "install.sh")
    File.cp!(Path.join(@root, "deploy/self-hosted/install.sh"), installer)

    # Stop immediately after generating/checking configuration, before any
    # images, containers or external services could be used.
    docker = Path.join(bin, "docker")

    File.write!(docker, """
    #!/bin/sh
    case "$*" in
      *"config --quiet"*) exit 41 ;;
      *) exit 0 ;;
    esac
    """)

    File.chmod!(docker, 0o755)

    for command <- ["lsof", "ss"] do
      path = Path.join(bin, command)
      File.write!(path, "#!/bin/sh\nexit 1\n")
      File.chmod!(path, 0o755)
    end

    %{installer: installer, env_file: Path.join(tmp_dir, ".env"), bin: bin}
  end

  test "persists a proxy address away from the first service allocations", context do
    assert {_output, 41} = install(context)
    config = File.read!(context.env_file)
    assert config =~ "MAVE_DOCKER_SUBNET=172.30.0.0/24\n"
    assert config =~ "MAVE_CADDY_INTERNAL_IP=172.30.0.254\n"
    assert Bitwise.band(File.stat!(context.env_file).mode, 0o777) == 0o600

    compose = File.read!(Path.join(@root, "deploy/self-hosted/compose.yml"))
    assert compose =~ "MAVE_TRUSTED_PROXY_CIDRS: ${MAVE_CADDY_INTERNAL_IP:-172.30.0.254}/32"
    assert compose =~ "ipv4_address: ${MAVE_CADDY_INTERNAL_IP:-172.30.0.254}"
  end

  test "persists a custom network and retains all configuration on rerun", context do
    assert {_output, 41} =
             install(context, [
               {"MAVE_DOCKER_SUBNET", "172.29.229.0/24"},
               {"MAVE_CADDY_INTERNAL_IP", "172.29.229.254"}
             ])

    config = File.read!(context.env_file)
    assert config =~ "MAVE_DOCKER_SUBNET=172.29.229.0/24\n"
    assert config =~ "MAVE_CADDY_INTERNAL_IP=172.29.229.254\n"
    assert {_output, 41} = install(context)
    assert File.read!(context.env_file) == config
  end

  test "generates a private distribution cookie", context do
    assert {_output, 41} = install(context)
    assert File.read!(context.env_file) =~ ~r/^RELEASE_COOKIE=[0-9a-f]{64}$/m

    # Every Core service loads .env, which delivers the cookie to the release.
    assert File.read!(Path.join(@root, "deploy/self-hosted/compose.yml")) =~ "path: .env"
  end

  test "adds a distribution cookie to an older configuration once", context do
    assert {_output, 41} = install(context)

    legacy_config =
      context.env_file
      |> File.read!()
      |> String.replace(~r/^RELEASE_COOKIE=.*\n/m, "")
      |> String.trim_trailing("\n")

    File.write!(context.env_file, legacy_config)

    assert {output, 41} = install(context)
    assert output =~ "Added a distribution cookie"
    config = File.read!(context.env_file)
    assert String.starts_with?(config, legacy_config <> "\nRELEASE_COOKIE=")
    assert config =~ ~r/\nRELEASE_COOKIE=[0-9a-f]{64}\n\z/

    assert {output, 41} = install(context)
    refute output =~ "Added a distribution cookie"
    assert File.read!(context.env_file) == config
  end

  defp install(context, overrides \\ []) do
    env = [
      {"PATH", context.bin <> ":" <> System.fetch_env!("PATH")},
      {"MAVE_DOCKER_SUBNET", nil},
      {"MAVE_CADDY_INTERNAL_IP", nil}
    ]

    System.cmd(
      "sh",
      [context.installer, "--owner-email", "installer@example.test", "--non-interactive"],
      env: Enum.reject(env, fn {key, _} -> List.keymember?(overrides, key, 0) end) ++ overrides,
      stderr_to_stdout: true
    )
  end
end
