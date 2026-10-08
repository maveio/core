defmodule MaveCore.FLAMEK8sBackend do
  @moduledoc false
  @behaviour FLAME.Backend

  require Logger
  alias FLAME.Parent
  alias MaveCore.SafeFile

  @service_account_token_path "/var/run/secrets/kubernetes.io/serviceaccount/token"
  @service_account_ca_path "/var/run/secrets/kubernetes.io/serviceaccount/ca.crt"
  @service_account_namespace_path "/var/run/secrets/kubernetes.io/serviceaccount/namespace"

  defstruct runner_pod_manifest: nil,
            parent_ref: nil,
            runner_node_name: nil,
            runner_pod_name: nil,
            cleanup_monitor_pid: nil,
            boot_timeout: 30_000,
            remote_terminator_pid: nil,
            log: false,
            k8s_url: nil,
            k8s_token: nil,
            k8s_transport_opts: [],
            k8s_namespace: "default"

  @impl true
  def init(opts) do
    # 1. Parse Options
    image = opts[:image] || raise ArgumentError, "missing :image"
    namespace = opts[:namespace] || infer_namespace() || "default"
    cpu_request = opts[:cpu_request] || "100m"
    memory_request = opts[:memory_request] || "128Mi"
    ephemeral_storage_request = opts[:ephemeral_storage_request]
    cpu_limit = resource_limit(opts, :cpu_limit, "4")
    memory_limit = resource_limit(opts, :memory_limit, "8Gi")
    ephemeral_storage_limit = resource_limit(opts, :ephemeral_storage_limit, "24Gi")
    env_vars = opts[:env] || []
    erl_aflags = Keyword.get(opts, :erl_aflags, "-hidden")
    boot_timeout = opts[:boot_timeout] || 30_000
    pod_generate_name = Keyword.get(opts, :pod_generate_name, "flame-runner-")
    labels = build_labels(Keyword.get(opts, :labels, %{}))

    # 2. Get K8s credentials (in-cluster or kubeconfig)
    {k8s_url, k8s_token, k8s_transport_opts} = get_k8s_credentials(opts[:kubeconfig])

    owner_reference =
      parent_pod_owner_reference(
        k8s_url,
        k8s_token,
        k8s_transport_opts,
        namespace,
        parent_pod_name(opts)
      )

    # 3. Construct Manifest
    parent_ref = make_ref()

    # Encode Parent for FLAME handshake
    parent = Parent.new(parent_ref, self(), __MODULE__, "flame-runner", "POD_IP")
    encoded_parent = Parent.encode(parent)

    parent_ip = System.get_env("FLAME_PARENT_IP")
    host_aliases = build_host_aliases(parent_ip)

    manifest = %{
      "apiVersion" => "v1",
      "kind" => "Pod",
      "metadata" =>
        %{
          "generateName" => pod_generate_name,
          "namespace" => namespace,
          "labels" => labels
        }
        |> maybe_put_owner_reference(owner_reference),
      "spec" =>
        build_pod_spec(
          opts,
          host_aliases,
          image,
          cpu_request,
          memory_request,
          ephemeral_storage_request,
          cpu_limit,
          memory_limit,
          ephemeral_storage_limit,
          env_vars,
          encoded_parent,
          erl_aflags
        )
    }

    state = %__MODULE__{
      runner_pod_manifest: manifest,
      parent_ref: parent_ref,
      k8s_url: k8s_url,
      k8s_token: k8s_token,
      k8s_transport_opts: k8s_transport_opts,
      k8s_namespace: namespace,
      boot_timeout: boot_timeout,
      log: opts[:log] || false
    }

    {:ok, state}
  end

  defp resource_limit(opts, key, default), do: opts[key] || default

  # In-cluster: read from ServiceAccount mounted secrets
  # Out-of-cluster: use kubeconfig file
  defp get_k8s_credentials(nil) do
    if File.exists?(@service_account_token_path) and File.exists?(@service_account_ca_path) do
      # sobelow_skip ["Traversal.FileModule"]
      token = File.read!(@service_account_token_path)
      # In-cluster API server is always at this address
      host = System.get_env("KUBERNETES_SERVICE_HOST")
      port = System.get_env("KUBERNETES_SERVICE_PORT", "443")
      url = "https://#{host}:#{port}"
      {url, token, [verify: :verify_peer, cacertfile: @service_account_ca_path]}
    else
      raise ArgumentError,
            "missing :kubeconfig and not running in-cluster (no ServiceAccount token found)"
    end
  end

  defp get_k8s_credentials(kubeconfig_path) do
    parse_kubeconfig(kubeconfig_path)
  end

  defp infer_namespace do
    if File.exists?(@service_account_namespace_path) do
      # sobelow_skip ["Traversal.FileModule"]
      File.read!(@service_account_namespace_path) |> String.trim()
    else
      nil
    end
  end

  # credo:disable-for-next-line Credo.Check.Refactor.FunctionArity
  defp build_pod_spec(
         opts,
         host_aliases,
         image,
         cpu_request,
         memory_request,
         ephemeral_storage_request,
         cpu_limit,
         memory_limit,
         ephemeral_storage_limit,
         env_vars,
         encoded_parent,
         erl_aflags
       ) do
    resources =
      %{
        "requests" =>
          %{
            "cpu" => cpu_request,
            "memory" => memory_request
          }
          |> maybe_put_resource("ephemeral-storage", ephemeral_storage_request)
      }
      |> maybe_put_limits(cpu_limit, memory_limit, ephemeral_storage_limit)

    base_spec = %{
      "hostAliases" => host_aliases,
      "restartPolicy" => "Never",
      "serviceAccountName" => opts[:service_account] || "default",
      "automountServiceAccountToken" => false,
      "securityContext" => %{
        "runAsNonRoot" => true,
        "runAsUser" => Keyword.get(opts, :run_as_user, 65_534),
        "runAsGroup" => Keyword.get(opts, :run_as_group, 65_534),
        "fsGroup" => Keyword.get(opts, :run_as_group, 65_534),
        "seccompProfile" => %{"type" => "RuntimeDefault"}
      },
      "volumes" => [
        %{
          "name" => "scratch",
          "emptyDir" => %{"sizeLimit" => Keyword.get(opts, :scratch_size_limit, "20Gi")}
        }
      ],
      "containers" => [
        %{
          "name" => "runner",
          "image" => image,
          "resources" => resources,
          "securityContext" => %{
            "allowPrivilegeEscalation" => false,
            "readOnlyRootFilesystem" => true,
            "capabilities" => %{"drop" => ["ALL"]}
          },
          "volumeMounts" => [
            %{"name" => "scratch", "mountPath" => "/tmp"},
            %{"name" => "scratch", "mountPath" => "/var/tmp"}
          ],
          "env" => build_env(env_vars, encoded_parent, erl_aflags)
        }
      ]
    }

    # Add imagePullSecrets if provided (required for private registries)
    spec_with_secrets =
      case opts[:image_pull_secrets] do
        nil ->
          base_spec

        [] ->
          base_spec

        secrets when is_list(secrets) ->
          Map.put(base_spec, "imagePullSecrets", Enum.map(secrets, &%{"name" => &1}))

        secret when is_binary(secret) ->
          Map.put(base_spec, "imagePullSecrets", [%{"name" => secret}])
      end

    spec_with_tolerations =
      spec_with_secrets
      |> maybe_put_tolerations(opts[:tolerations])
      |> maybe_put_runtime_class(opts[:runtime_class_name])

    # Add nodeSelector if provided (for scheduling to specific node pools)
    case opts[:node_selector] do
      nil ->
        spec_with_tolerations

      selector when is_map(selector) ->
        Map.put(spec_with_tolerations, "nodeSelector", selector)
    end
  end

  defp maybe_put_runtime_class(spec, nil), do: spec

  defp maybe_put_runtime_class(spec, name) when is_binary(name),
    do: Map.put(spec, "runtimeClassName", name)

  defp maybe_put_tolerations(spec, nil), do: spec
  defp maybe_put_tolerations(spec, []), do: spec

  defp maybe_put_tolerations(spec, tolerations) when is_list(tolerations) do
    normalized_tolerations =
      tolerations
      |> Enum.map(&normalize_toleration/1)
      |> Enum.reject(&(&1 == %{}))

    case normalized_tolerations do
      [] -> spec
      _tolerations -> Map.put(spec, "tolerations", normalized_tolerations)
    end
  end

  defp maybe_put_tolerations(spec, _tolerations), do: spec

  defp normalize_toleration(toleration) when is_map(toleration) do
    Map.new(toleration, fn {key, value} -> {to_string(key), value} end)
  end

  defp normalize_toleration(_toleration), do: %{}

  defp maybe_put_limits(resources, nil, nil, nil), do: resources

  defp maybe_put_limits(resources, cpu_limit, memory_limit, ephemeral_storage_limit) do
    limits =
      %{}
      |> maybe_put_resource("cpu", cpu_limit)
      |> maybe_put_resource("memory", memory_limit)
      |> maybe_put_resource("ephemeral-storage", ephemeral_storage_limit)

    Map.put(resources, "limits", limits)
  end

  defp maybe_put_resource(resources, _name, nil), do: resources
  defp maybe_put_resource(resources, name, value), do: Map.put(resources, name, value)

  defp build_labels(labels) do
    %{"app" => "flame-runner"}
    |> Map.merge(normalize_labels(labels))
  end

  defp normalize_labels(labels) when is_map(labels) do
    Map.new(labels, fn {key, value} -> {to_string(key), to_string(value)} end)
  end

  defp normalize_labels(labels) when is_list(labels) do
    labels
    |> Enum.filter(fn
      {key, value} -> not is_nil(key) and not is_nil(value)
      _other -> false
    end)
    |> Map.new(fn {key, value} -> {to_string(key), to_string(value)} end)
  end

  defp normalize_labels(_labels), do: %{}

  @impl true
  def remote_spawn_monitor(%__MODULE__{} = state, term) do
    case term do
      func when is_function(func, 0) ->
        {pid, ref} = Node.spawn_monitor(state.runner_node_name, func)
        {:ok, {pid, ref}}

      {mod, fun, args} when is_atom(mod) and is_atom(fun) and is_list(args) ->
        {pid, ref} = Node.spawn_monitor(state.runner_node_name, mod, fun, args)
        {:ok, {pid, ref}}

      other ->
        raise ArgumentError,
              "expected a null arity function or {mod, func, args}. Got: #{inspect(other)}"
    end
  end

  @impl true
  def system_shutdown do
    System.stop()
  end

  @impl true
  def remote_boot(%__MODULE__{parent_ref: parent_ref} = state) do
    log(state, "Remote Booting Runner...")

    {booted_state, req_connect_time} =
      with_elapsed_ms(fn ->
        case create_pod(state) do
          {:ok, pod} ->
            log(state, "Runner pod created", pod_ip: pod["status"]["podIP"])

            maybe_log_boot_timing("pod_created",
              pod_name: pod["metadata"]["name"],
              pod_ip: pod["status"]["podIP"]
            )

            booted_state = %{state | runner_pod_name: pod["metadata"]["name"]}
            cleanup_monitor_pid = start_cleanup_monitor(booted_state)
            %{booted_state | cleanup_monitor_pid: cleanup_monitor_pid}

          {:error, reason} ->
            Logger.error("Failed to create runner pod: #{inspect(reason)}")
            exit(:timeout)
        end
      end)

    remaining_window = max(state.boot_timeout - req_connect_time, 0)

    maybe_log_boot_timing("pod_ready_for_connect",
      create_and_ip_wait_ms: req_connect_time,
      remaining_window_ms: remaining_window
    )

    log(state, "Waiting for Remote UP...", remaining_window: remaining_window)

    handshake_started_at = System.monotonic_time(:millisecond)

    receive do
      {^parent_ref, {:remote_up, remote_terminator_pid}} ->
        log(state, "Remote FLAME is Up!")
        send(booted_state.cleanup_monitor_pid, {:monitor_remote, remote_terminator_pid})

        handshake_duration_ms = System.monotonic_time(:millisecond) - handshake_started_at
        total_boot_ms = req_connect_time + handshake_duration_ms

        maybe_log_boot_timing("remote_up",
          runner_node_name: node(remote_terminator_pid),
          pod_create_and_ip_wait_ms: req_connect_time,
          remote_up_wait_ms: handshake_duration_ms,
          total_boot_ms: total_boot_ms
        )

        new_state = %{
          booted_state
          | remote_terminator_pid: remote_terminator_pid,
            runner_node_name: node(remote_terminator_pid)
        }

        {:ok, remote_terminator_pid, new_state}
    after
      remaining_window ->
        maybe_log_boot_timing("remote_up_timeout",
          pod_create_and_ip_wait_ms: req_connect_time,
          remaining_window_ms: remaining_window
        )

        Logger.error("Timeout waiting for runner to connect back")
        # Cleanup pod?
        exit(:timeout)
    end
  end

  @impl true
  def handle_info(msg, state) do
    log(state, "Missed message: #{inspect(msg)}")
    {:noreply, state}
  end

  # -- Helpers --

  defp parse_kubeconfig(path) do
    content = SafeFile.read!(path, max_bytes: SafeFile.kubeconfig_bytes_limit())

    # Extract Server URL
    [_, server] =
      Regex.run(~r/server:\s+(https?:\/\/[^\s]+)/, content) ||
        raise "Could not find server in kubeconfig"

    # Extract Token (Assuming token based auth as seen in checks)
    # If using certs, this backend needs expansion.
    token =
      case Regex.run(~r/token:\s+([^\s]+)/, content) do
        [_, t] ->
          t

        nil ->
          # Fallback: Check if user part has token
          # This is a very basic parser.
          # Ideally we'd use a YAML parser or Kubeconfig library
          raise "Could not find token in kubeconfig. This backend currently supports token-based auth only."
      end

    {validate_k8s_server!(server), token, kubeconfig_transport_opts(path, content)}
  end

  defp validate_k8s_server!(server) do
    case URI.parse(server) do
      %URI{scheme: "https", host: host} when is_binary(host) and host != "" ->
        server

      _other ->
        raise ArgumentError, "Kubernetes API server must use HTTPS"
    end
  end

  defp kubeconfig_transport_opts(kubeconfig_path, content) do
    ca_opts =
      cond do
        match = Regex.run(~r/certificate-authority-data:\s+([^\s]+)/, content) ->
          [_, encoded_ca] = match
          [cacerts: decode_certificate_authority_data!(encoded_ca)]

        match = Regex.run(~r/certificate-authority:\s+([^\s]+)/, content) ->
          [_, ca_path] = match
          [cacertfile: expand_kubeconfig_path(ca_path, kubeconfig_path)]

        true ->
          []
      end

    [verify: :verify_peer] ++ ca_opts
  end

  defp decode_certificate_authority_data!(encoded_ca) do
    decoded_ca =
      encoded_ca
      |> String.trim(~s("'"))
      |> Base.decode64!()

    case :public_key.pem_decode(decoded_ca) do
      [] ->
        [decoded_ca]

      entries ->
        Enum.flat_map(entries, fn
          {:Certificate, der, _encryption} -> [der]
          _other -> []
        end)
    end
  end

  defp expand_kubeconfig_path(ca_path, kubeconfig_path) do
    ca_path
    |> String.trim(~s("'"))
    |> Path.expand(Path.dirname(kubeconfig_path))
  end

  defp parent_pod_name(opts) do
    case Keyword.fetch(opts, :parent_pod_name) do
      {:ok, name} -> name
      :error -> if is_nil(opts[:kubeconfig]), do: System.get_env("POD_NAME")
    end
  end

  defp parent_pod_owner_reference(
         _k8s_url,
         _k8s_token,
         _k8s_transport_opts,
         _namespace,
         parent_pod_name
       )
       when parent_pod_name in [nil, ""],
       do: nil

  defp parent_pod_owner_reference(
         k8s_url,
         k8s_token,
         k8s_transport_opts,
         namespace,
         parent_pod_name
       ) do
    url = "#{k8s_url}/api/v1/namespaces/#{namespace}/pods/#{parent_pod_name}"

    req_opts = [
      headers: [{"Authorization", "Bearer #{k8s_token}"}],
      connect_options: [transport_opts: k8s_transport_opts]
    ]

    case Req.get(url, req_opts) do
      {:ok,
       %{
         status: 200,
         body: %{"metadata" => %{"name" => name, "uid" => uid}}
       }}
      when is_binary(name) and is_binary(uid) ->
        %{"apiVersion" => "v1", "kind" => "Pod", "name" => name, "uid" => uid}

      {:ok, %{status: status}} ->
        Logger.warning(
          "Could not add owner reference to FLAME runner pod: Kubernetes API returned #{status}"
        )

        nil

      {:error, _reason} ->
        Logger.warning(
          "Could not add owner reference to FLAME runner pod: Kubernetes API request failed"
        )

        nil
    end
  end

  defp maybe_put_owner_reference(metadata, nil), do: metadata

  defp maybe_put_owner_reference(metadata, owner_reference) do
    Map.put(metadata, "ownerReferences", [owner_reference])
  end

  defp create_pod(state) do
    url = "#{state.k8s_url}/api/v1/namespaces/#{state.k8s_namespace}/pods"

    req_opts = [
      json: state.runner_pod_manifest,
      headers: [{"Authorization", "Bearer #{state.k8s_token}"}],
      connect_options: [transport_opts: state.k8s_transport_opts]
    ]

    case Req.post(url, req_opts) do
      {:ok, %{status: 201, body: pod}} ->
        # Pod created. Wait for IP.
        wait_for_pod_ip(state, pod["metadata"]["name"])

      {:ok, %{status: code, body: body}} ->
        {:error, "K8s API Error #{code}: #{inspect(body)}"}

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp wait_for_pod_ip(state, name, retries \\ 30) do
    if retries == 0, do: {:error, :timeout_waiting_for_ip}

    url = "#{state.k8s_url}/api/v1/namespaces/#{state.k8s_namespace}/pods/#{name}"

    req_opts = [
      headers: [{"Authorization", "Bearer #{state.k8s_token}"}],
      connect_options: [transport_opts: state.k8s_transport_opts]
    ]

    case Req.get(url, req_opts) do
      {:ok, %{status: 200, body: pod}} ->
        case pod["status"]["podIP"] do
          ip when is_binary(ip) ->
            {:ok, pod}

          _ ->
            Process.sleep(1000)
            wait_for_pod_ip(state, name, retries - 1)
        end

      _ ->
        Process.sleep(1000)
        wait_for_pod_ip(state, name, retries - 1)
    end
  end

  defp build_env(user_env, encoded_parent, erl_aflags) do
    # Convert [{"Name", "Val"}] to K8s format
    base_env =
      Enum.map(user_env, fn {k, v} ->
        %{"name" => to_string(k), "value" => to_string(v)}
      end)

    defaults =
      [
        %{"name" => "PHX_SERVER", "value" => "false"},
        %{"name" => "FLAME_PARENT", "value" => encoded_parent},
        %{"name" => "RELEASE_DISTRIBUTION", "value" => "name"},
        %{"name" => "RELEASE_COOKIE", "value" => Node.get_cookie()},
        # Downward API
        %{
          "name" => "POD_NAME",
          "valueFrom" => %{"fieldRef" => %{"fieldPath" => "metadata.name"}}
        },
        %{
          "name" => "POD_NAMESPACE",
          "valueFrom" => %{"fieldRef" => %{"fieldPath" => "metadata.namespace"}}
        },
        %{"name" => "POD_IP", "valueFrom" => %{"fieldRef" => %{"fieldPath" => "status.podIP"}}},
        %{
          "name" => "NODE_NAME",
          "valueFrom" => %{"fieldRef" => %{"fieldPath" => "spec.nodeName"}}
        },
        # Node name construction depends on IP
        %{"name" => "RELEASE_NODE", "value" => "mave_core@$(POD_IP)"}
        # Note: The app name in RELEASE_NODE usually must match the release Name.
        # "mave_core" is the app name.
      ]
      |> maybe_add_env("ERL_AFLAGS", erl_aflags)

    put_new_env(base_env, defaults)
  end

  defp maybe_add_env(env, _name, nil), do: env
  defp maybe_add_env(env, _name, ""), do: env
  defp maybe_add_env(env, name, value), do: env ++ [%{"name" => name, "value" => value}]

  defp put_new_env(base_env, defaults) do
    existing_names = MapSet.new(base_env, & &1["name"])

    base_env ++ Enum.reject(defaults, &MapSet.member?(existing_names, &1["name"]))
  end

  defp with_elapsed_ms(func) do
    {micro, result} = :timer.tc(func)
    {result, div(micro, 1000)}
  end

  defp maybe_log_boot_timing(event, meta) do
    if Application.get_env(:mave_core, :flow_timing_logs, false) do
      Logger.info("flame_boot_timing #{event} #{inspect(meta)}")
    end
  end

  defp start_cleanup_monitor(%__MODULE__{} = state) do
    parent_pid = self()

    {:ok, cleanup_monitor_pid} =
      Task.start(fn ->
        parent_monitor_ref = Process.monitor(parent_pid)
        cleanup_monitor(state, parent_monitor_ref, nil)
      end)

    cleanup_monitor_pid
  end

  defp cleanup_monitor(state, parent_monitor_ref, remote_monitor_ref) do
    receive do
      {:monitor_remote, remote_terminator_pid} when is_pid(remote_terminator_pid) ->
        cleanup_monitor(
          state,
          parent_monitor_ref,
          Process.monitor(remote_terminator_pid)
        )

      {:DOWN, ^parent_monitor_ref, :process, _pid, _reason} ->
        delete_runner_pod(state)

      {:DOWN, ^remote_monitor_ref, :process, _pid, _reason}
      when is_reference(remote_monitor_ref) ->
        delete_runner_pod(state)

      _other ->
        cleanup_monitor(state, parent_monitor_ref, remote_monitor_ref)
    end
  end

  defp delete_runner_pod(%__MODULE__{runner_pod_name: pod_name} = state) do
    url = "#{state.k8s_url}/api/v1/namespaces/#{state.k8s_namespace}/pods/#{pod_name}"

    req_opts = [
      headers: [{"Authorization", "Bearer #{state.k8s_token}"}],
      connect_options: [transport_opts: state.k8s_transport_opts]
    ]

    case Req.delete(url, req_opts) do
      {:ok, %{status: status}} when status in [200, 202, 404] ->
        :ok

      {:ok, %{status: status}} ->
        Logger.warning(
          "Failed to delete FLAME runner pod #{state.k8s_namespace}/#{pod_name}: #{status}"
        )

      {:error, _reason} ->
        Logger.warning(
          "Failed to delete FLAME runner pod #{state.k8s_namespace}/#{pod_name}: Kubernetes API request failed"
        )
    end
  end

  defp build_host_aliases(nil), do: []

  defp build_host_aliases(ip) do
    # Node.self() returns :"app@hostname"
    node_host = Node.self() |> Atom.to_string() |> String.split("@") |> List.last()

    [
      %{"ip" => ip, "hostnames" => [node_host]}
    ]
  end

  defp log(%{log: true}, msg, meta), do: Logger.info("FLAMEK8sBackend: #{msg} #{inspect(meta)}")
  defp log(_, _, _), do: :ok

  defp log(state, msg), do: log(state, msg, [])
end
