defmodule MaveCore.FLAMEK8sBackendTest do
  use ExUnit.Case, async: true

  @tls_fixture_dir Path.expand("../fixtures/k8s_tls", __DIR__)

  test "init keeps the FLAME pool boot timeout" do
    kubeconfig_path =
      Path.join(System.tmp_dir!(), "mave-kubeconfig-#{System.unique_integer([:positive])}")

    File.write!(kubeconfig_path, """
    clusters:
    - cluster:
        server: https://kubernetes.example.test
    users:
    - user:
        token: test-token
    """)

    on_exit(fn -> File.rm(kubeconfig_path) end)

    assert {:ok, state} =
             MaveCore.FLAMEK8sBackend.init(
               image: "example.test/mave:latest",
               kubeconfig: kubeconfig_path,
               boot_timeout: 300_000
             )

    assert state.boot_timeout == 300_000
    assert state.k8s_transport_opts == [verify: :verify_peer]
  end

  test "runner pod manifest never mounts service account credentials" do
    kubeconfig_path = write_kubeconfig(443)

    assert {:ok, state} =
             MaveCore.FLAMEK8sBackend.init(
               image: "example.test/mave:latest",
               kubeconfig: kubeconfig_path,
               service_account: "mave-core",
               automount_service_account_token: true
             )

    assert get_in(state.runner_pod_manifest, ["spec", "serviceAccountName"]) == "mave-core"
    assert get_in(state.runner_pod_manifest, ["spec", "automountServiceAccountToken"]) == false
  end

  test "runner pods use restricted security settings and bounded scratch" do
    assert {:ok, state} =
             MaveCore.FLAMEK8sBackend.init(
               image: "example.test/mave:latest",
               kubeconfig: write_kubeconfig(443),
               runtime_class_name: "isolated",
               cpu_limit: nil,
               memory_limit: nil,
               ephemeral_storage_limit: nil,
               scratch_size_limit: "12Gi"
             )

    spec = state.runner_pod_manifest["spec"]
    assert spec["runtimeClassName"] == "isolated"
    assert spec["securityContext"]["runAsNonRoot"]
    assert spec["securityContext"]["runAsUser"] == 65_534
    assert spec["securityContext"]["seccompProfile"] == %{"type" => "RuntimeDefault"}
    assert spec["volumes"] == [%{"name" => "scratch", "emptyDir" => %{"sizeLimit" => "12Gi"}}]
    [container] = spec["containers"]

    assert container["securityContext"] == %{
             "allowPrivilegeEscalation" => false,
             "readOnlyRootFilesystem" => true,
             "capabilities" => %{"drop" => ["ALL"]}
           }

    assert container["resources"]["limits"] == %{
             "cpu" => "4",
             "memory" => "8Gi",
             "ephemeral-storage" => "24Gi"
           }

    assert Enum.map(container["volumeMounts"], & &1["mountPath"]) == ["/tmp", "/var/tmp"]
  end

  test "runner pod manifest is owned by its parent pod" do
    {probe, port} = start_https_k8s_api()
    ca_pem = File.read!(Path.join(@tls_fixture_dir, "ca.pem"))
    kubeconfig_path = write_kubeconfig(port, ca_pem)

    assert {:ok, state} =
             MaveCore.FLAMEK8sBackend.init(
               image: "example.test/mave:latest",
               kubeconfig: kubeconfig_path,
               parent_pod_name: "parent-test"
             )

    assert get_in(state.runner_pod_manifest, ["metadata", "ownerReferences"]) == [
             %{
               "apiVersion" => "v1",
               "kind" => "Pod",
               "name" => "parent-test",
               "uid" => "parent-uid"
             }
           ]

    assert_received {:k8s_api_request, "GET", "/api/v1/namespaces/default/pods/parent-test",
                     "Bearer test-token", nil}

    assert Agent.get(probe, & &1.parent_ref) == nil
  end

  test "runner pod manifest includes downward API pod identity" do
    kubeconfig_path =
      Path.join(System.tmp_dir!(), "mave-kubeconfig-#{System.unique_integer([:positive])}")

    File.write!(kubeconfig_path, """
    clusters:
    - cluster:
        server: https://kubernetes.example.test
    users:
    - user:
        token: test-token
    """)

    on_exit(fn -> File.rm(kubeconfig_path) end)

    assert {:ok, state} =
             MaveCore.FLAMEK8sBackend.init(
               image: "example.test/mave:latest",
               kubeconfig: kubeconfig_path
             )

    env =
      state.runner_pod_manifest
      |> get_in(["spec", "containers", Access.at(0), "env"])
      |> Map.new(&{&1["name"], &1})

    assert get_in(env, ["POD_NAME", "valueFrom", "fieldRef", "fieldPath"]) == "metadata.name"

    assert get_in(env, ["POD_NAMESPACE", "valueFrom", "fieldRef", "fieldPath"]) ==
             "metadata.namespace"
  end

  test "runner pod manifest starts hidden Erlang nodes" do
    kubeconfig_path =
      Path.join(System.tmp_dir!(), "mave-kubeconfig-#{System.unique_integer([:positive])}")

    File.write!(kubeconfig_path, """
    clusters:
    - cluster:
        server: https://kubernetes.example.test
    users:
    - user:
        token: test-token
    """)

    on_exit(fn -> File.rm(kubeconfig_path) end)

    assert {:ok, state} =
             MaveCore.FLAMEK8sBackend.init(
               image: "example.test/mave:latest",
               kubeconfig: kubeconfig_path
             )

    env =
      state.runner_pod_manifest
      |> get_in(["spec", "containers", Access.at(0), "env"])
      |> Map.new(&{&1["name"], &1["value"]})

    assert env["ERL_AFLAGS"] == "-hidden"
  end

  test "runner pod manifest includes configured tolerations" do
    kubeconfig_path =
      Path.join(System.tmp_dir!(), "mave-kubeconfig-#{System.unique_integer([:positive])}")

    File.write!(kubeconfig_path, """
    clusters:
    - cluster:
        server: https://kubernetes.example.test
    users:
    - user:
        token: test-token
    """)

    on_exit(fn -> File.rm(kubeconfig_path) end)

    assert {:ok, state} =
             MaveCore.FLAMEK8sBackend.init(
               image: "example.test/mave:latest",
               kubeconfig: kubeconfig_path,
               tolerations: [
                 %{
                   key: "mave.io/dedicated",
                   operator: "Equal",
                   value: "media",
                   effect: "NoSchedule"
                 }
               ]
             )

    assert get_in(state.runner_pod_manifest, ["spec", "tolerations"]) == [
             %{
               "key" => "mave.io/dedicated",
               "operator" => "Equal",
               "value" => "media",
               "effect" => "NoSchedule"
             }
           ]
  end

  test "rejects an untrusted Kubernetes API before sending credentials or pod secrets" do
    {probe, port} = start_https_k8s_api()
    kubeconfig_path = write_kubeconfig(port)

    assert {:ok, state} =
             MaveCore.FLAMEK8sBackend.init(
               image: "example.test/mave:latest",
               kubeconfig: kubeconfig_path,
               boot_timeout: 100,
               env: [{"SECRET_KEY_BASE", "must-not-reach-untrusted-server"}]
             )

    Agent.update(probe, &Map.put(&1, :parent_ref, state.parent_ref))

    assert catch_exit(MaveCore.FLAMEK8sBackend.remote_boot(state)) == :timeout
    refute_received {:k8s_api_request, _, _, _, _}
  end

  test "trusts the Kubernetes API CA from kubeconfig and preserves authenticated requests" do
    {probe, port} = start_https_k8s_api()
    ca_pem = File.read!(Path.join(@tls_fixture_dir, "ca.pem"))
    kubeconfig_path = write_kubeconfig(port, ca_pem)

    remote_terminator_pid =
      start_supervised!(
        {Task,
         fn ->
           receive do
             :stop -> :ok
           end
         end}
      )

    assert {:ok, state} =
             MaveCore.FLAMEK8sBackend.init(
               image: "example.test/mave:latest",
               kubeconfig: kubeconfig_path,
               boot_timeout: 1_000,
               env: [{"SECRET_KEY_BASE", "trusted-server-secret"}]
             )

    Agent.update(probe, fn probe_state ->
      %{
        probe_state
        | parent_ref: state.parent_ref,
          remote_terminator_pid: remote_terminator_pid
      }
    end)

    assert {:ok, ^remote_terminator_pid, booted_state} =
             MaveCore.FLAMEK8sBackend.remote_boot(state)

    assert booted_state.runner_node_name == node()

    assert_received {:k8s_api_request, "POST", "/api/v1/namespaces/default/pods",
                     "Bearer test-token", body}

    assert body =~ "trusted-server-secret"

    assert_received {:k8s_api_request, "GET", "/api/v1/namespaces/default/pods/runner-test",
                     "Bearer test-token", nil}

    remote_monitor_ref = Process.monitor(remote_terminator_pid)
    send(remote_terminator_pid, :stop)
    assert_receive {:DOWN, ^remote_monitor_ref, :process, ^remote_terminator_pid, :normal}

    assert_receive {:k8s_api_request, "DELETE", "/api/v1/namespaces/default/pods/runner-test",
                    "Bearer test-token", nil},
                   1_000
  end

  test "rejects plaintext Kubernetes API URLs" do
    kubeconfig_path = write_kubeconfig(8080, nil, "http")

    assert_raise ArgumentError, "Kubernetes API server must use HTTPS", fn ->
      MaveCore.FLAMEK8sBackend.init(
        image: "example.test/mave:latest",
        kubeconfig: kubeconfig_path
      )
    end
  end

  test "resolves a relative kubeconfig CA file" do
    fixture_dir =
      Path.join(System.tmp_dir!(), "mave-kubeconfig-#{System.unique_integer([:positive])}")

    kubeconfig_path = Path.join(fixture_dir, "config")
    ca_path = Path.join(fixture_dir, "cluster-ca.pem")
    File.mkdir_p!(fixture_dir)
    File.write!(ca_path, File.read!(Path.join(@tls_fixture_dir, "ca.pem")))

    File.write!(kubeconfig_path, """
    clusters:
    - cluster:
        server: https://kubernetes.example.test
        certificate-authority: cluster-ca.pem
    users:
    - user:
        token: test-token
    """)

    on_exit(fn -> File.rm_rf(fixture_dir) end)

    assert {:ok, state} =
             MaveCore.FLAMEK8sBackend.init(
               image: "example.test/mave:latest",
               kubeconfig: kubeconfig_path
             )

    assert state.k8s_transport_opts == [verify: :verify_peer, cacertfile: ca_path]
  end

  defp start_https_k8s_api do
    owner = self()

    probe =
      start_supervised!(
        {Agent, fn -> %{owner: owner, parent_ref: nil, remote_terminator_pid: owner} end}
      )

    server =
      start_supervised!(
        {Bandit,
         scheme: :https,
         plug: {MaveCore.K8sAPITestPlug, probe: probe},
         ip: {127, 0, 0, 1},
         port: 0,
         certfile: Path.join(@tls_fixture_dir, "server.pem"),
         keyfile: Path.join(@tls_fixture_dir, "server-key.pem"),
         startup_log: false}
      )

    assert {:ok, {{127, 0, 0, 1}, port}} = ThousandIsland.listener_info(server)
    {probe, port}
  end

  defp write_kubeconfig(port, ca_pem \\ nil, scheme \\ "https") do
    kubeconfig_path =
      Path.join(System.tmp_dir!(), "mave-kubeconfig-#{System.unique_integer([:positive])}")

    ca_config =
      if ca_pem do
        "    certificate-authority-data: #{Base.encode64(ca_pem)}\n"
      else
        ""
      end

    File.write!(kubeconfig_path, """
    clusters:
    - cluster:
        server: #{scheme}://localhost:#{port}
    #{ca_config}users:
    - user:
        token: test-token
    """)

    on_exit(fn -> File.rm(kubeconfig_path) end)
    kubeconfig_path
  end
end
