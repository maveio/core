defmodule MaveCore.Application do
  # See https://hexdocs.pm/elixir/Application.html
  # for more information on OTP Applications
  @moduledoc false

  use Application
  require Logger

  @default_flame_pool_name MaveCore.Workers.FlameRunner
  @default_flame_timeout_ms 30 * 60 * 1000
  @default_flame_boot_timeout_ms 5 * 60 * 1000
  @default_flame_shutdown_timeout_ms 5 * 60 * 1000

  @impl true
  def start(_type, _args) do
    :ok = MaveCore.LogRedaction.install()
    runtime_policy = runtime_child_policy()
    flame_pool_config = Application.get_env(:mave_core, :flame_pool, [])
    children = supervision_children(runtime_policy, flame_pool_config)

    # See https://hexdocs.pm/elixir/Supervisor.html
    # for other strategies and supported options
    opts = [strategy: :one_for_one, name: MaveCore.Supervisor]
    Supervisor.start_link(children, opts)
  end

  defp supervision_children(runtime_policy, flame_pool_config) do
    base_children(runtime_policy) ++
      database_children(runtime_policy) ++
      endpoint_children(runtime_policy) ++
      flame_children(runtime_policy, flame_pool_config) ++
      flame_prewarmer_children(runtime_policy) ++
      oban_children(runtime_policy)
  end

  defp base_children(runtime_policy) do
    [MaveCoreWeb.Telemetry] ++ cluster_children(runtime_policy)
  end

  defp cluster_children(%{start_cluster_children: true}) do
    [
      {DNSCluster, query: Application.get_env(:mave_core, :dns_cluster_query) || :ignore},
      {Phoenix.PubSub, name: MaveCore.PubSub},
      {MaveCore.RateLimit, Application.get_env(:mave_core, MaveCore.RateLimit, [])},
      MaveCore.Media.ImageGenerationCache
    ]
  end

  defp cluster_children(_runtime_policy), do: []

  # Database children only start in the main app, not FLAME workers.
  defp database_children(%{start_databases: true}) do
    [
      MaveCore.Repo,
      MaveCore.ClickHouseRepo,
      MaveCore.Metrics.IngestionBuffer
    ]
  end

  defp database_children(_runtime_policy), do: []

  # The FLAME pool only starts in the main app; workers connect back to it.
  defp flame_children(%{start_flame_pool: true}, flame_pool_config) do
    flame_pool_config
    |> flame_pool_configs()
    |> Enum.map(fn {name, config} ->
      {FLAME.Pool, flame_pool_options(config, name)}
    end)
  end

  defp flame_children(_runtime_policy, _flame_pool_config), do: []

  defp flame_prewarmer_children(%{start_flame_prewarmer: true}) do
    :mave_core
    |> Application.get_env(
      :flame_prewarmers,
      Application.get_env(:mave_core, :flame_prewarmer, [])
    )
    |> flame_prewarmer_child_specs()
  end

  defp flame_prewarmer_children(_runtime_policy), do: []

  defp endpoint_children(%{start_endpoint: true}), do: [MaveCoreWeb.Endpoint]
  defp endpoint_children(_runtime_policy), do: []

  defp oban_children(%{start_oban: true} = runtime_policy) do
    case Application.get_env(:mave_core, Oban) do
      config when is_list(config) ->
        [{Oban, oban_runtime_config(config, runtime_policy)}]

      nil ->
        Logger.warning("Oban disabled: no :mave_core Oban config found")
        []

      other ->
        Logger.warning("Oban disabled: invalid Oban config #{inspect(other)}")
        []
    end
  end

  defp oban_children(_runtime_policy), do: []

  @doc false
  def runtime_child_policy(env \\ System.get_env()) when is_map(env) do
    flame_worker? = present_env?(Map.get(env, "FLAME_PARENT"))
    runtime_role = normalize_runtime_role(Map.get(env, "MAVE_RUNTIME_ROLE"))
    start_flame_pool? = not flame_worker? and start_flame_pool?(runtime_role, env)

    %{
      flame_worker: flame_worker?,
      runtime_role: runtime_role,
      start_cluster_children: not flame_worker?,
      start_databases: not flame_worker?,
      start_endpoint: not flame_worker?,
      start_flame_pool: start_flame_pool?,
      start_flame_prewarmer: start_flame_pool? and start_flame_prewarmer?(env),
      start_oban: not flame_worker? and start_oban?(runtime_role),
      run_oban_queues: not flame_worker? and run_oban_queues?(runtime_role)
    }
  end

  @doc false
  def oban_runtime_config(config, %{run_oban_queues: true}) when is_list(config), do: config

  def oban_runtime_config(config, %{run_oban_queues: false}) when is_list(config) do
    config
    |> Keyword.put(:queues, false)
    |> Keyword.put(:plugins, false)
    |> Keyword.put(:peer, false)
  end

  @doc false
  def flame_prewarmer_child_specs(config) when is_list(config) do
    config
    |> flame_prewarmer_configs()
    |> Enum.map(&{MaveCore.Workers.FlamePrewarmer, &1})
  end

  def flame_prewarmer_child_specs(_config), do: []

  @doc false
  def flame_pool_options(config, name \\ @default_flame_pool_name) when is_list(config) do
    [
      min: 0,
      max: 10,
      max_concurrency: 1,
      timeout: @default_flame_timeout_ms,
      boot_timeout: @default_flame_boot_timeout_ms,
      shutdown_timeout: @default_flame_shutdown_timeout_ms,
      idle_shutdown_after: 30_000
    ]
    |> Keyword.merge(config)
    |> put_pool_backend()
    |> Keyword.put(:name, name)
  end

  defp flame_pool_configs(default_config) do
    case Application.get_env(:mave_core, :flame_pools, []) do
      pools when is_list(pools) and pools != [] ->
        Enum.map(pools, fn
          {name, config} when is_atom(name) and is_list(config) ->
            {name, config}
        end)

      _other ->
        [{@default_flame_pool_name, default_config}]
    end
  end

  defp flame_prewarmer_configs(config) when is_list(config) do
    if Keyword.keyword?(config) do
      [config]
    else
      Enum.filter(config, &Keyword.keyword?/1)
    end
  end

  defp put_pool_backend(options) do
    case Keyword.pop(options, :backend_opts) do
      {nil, options} ->
        options

      {backend_opts, options} when is_list(backend_opts) ->
        Keyword.put(options, :backend, {MaveCore.FLAMEK8sBackend, backend_opts})
    end
  end

  # Tell Phoenix to update the endpoint configuration
  # whenever the application is updated.
  @impl true
  def config_change(changed, _new, removed) do
    MaveCoreWeb.Endpoint.config_change(changed, removed)
    :ok
  end

  defp start_flame_pool?(runtime_role, env) do
    case boolean_env_override(env, "MAVE_FLAME_ENABLED") do
      {:ok, enabled?} -> enabled?
      :unset -> runtime_role in [:default, :web, :image, :worker]
    end
  end

  defp start_oban?(runtime_role) do
    runtime_role in [:default, :web, :dashboard, :api, :image, :ingest, :worker]
  end

  defp start_flame_prewarmer?(env) do
    case boolean_env_override(env, "MAVE_FLAME_PREWARM_ENABLED") do
      {:ok, enabled?} -> enabled?
      :unset -> false
    end
  end

  defp run_oban_queues?(runtime_role) do
    runtime_role in [:default, :web, :worker]
  end

  defp normalize_runtime_role(nil), do: :default

  defp normalize_runtime_role(value) when is_binary(value) do
    case value |> String.trim() |> String.downcase() do
      "" -> :default
      "web" -> :web
      "dashboard" -> :dashboard
      "api" -> :api
      "image" -> :image
      "worker" -> :worker
      "ingest" -> :ingest
      _ -> :unknown
    end
  end

  defp normalize_runtime_role(_), do: :unknown

  defp boolean_env_override(env, name) do
    case Map.get(env, name) do
      nil -> :unset
      value when value in [true, false] -> {:ok, value}
      value when is_binary(value) -> parse_boolean_override(value)
      _ -> :unset
    end
  end

  defp parse_boolean_override(value) do
    case value |> String.trim() |> String.downcase() do
      value when value in ["1", "true", "yes", "on"] -> {:ok, true}
      value when value in ["0", "false", "no", "off"] -> {:ok, false}
      _ -> :unset
    end
  end

  defp present_env?(value) when is_binary(value), do: String.trim(value) != ""
  defp present_env?(_), do: false
end
