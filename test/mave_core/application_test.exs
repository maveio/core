defmodule MaveCore.ApplicationTest do
  use ExUnit.Case, async: true

  alias MaveCore.Application, as: MaveApplication

  describe "runtime_child_policy/1" do
    test "keeps legacy default nodes running Oban and FLAME" do
      policy = MaveApplication.runtime_child_policy(%{})

      assert policy.runtime_role == :default
      assert policy.start_cluster_children
      assert policy.start_databases
      assert policy.start_endpoint
      assert policy.start_flame_pool
      assert policy.start_oban
      assert policy.run_oban_queues
    end

    test "web nodes keep legacy all-in-one behavior" do
      policy = MaveApplication.runtime_child_policy(%{"MAVE_RUNTIME_ROLE" => "web"})

      assert policy.runtime_role == :web
      assert policy.start_databases
      assert policy.start_flame_pool
      assert policy.start_oban
      assert policy.run_oban_queues
    end

    test "dashboard and API nodes can enqueue without running jobs" do
      for role <- ["dashboard", "api"] do
        policy = MaveApplication.runtime_child_policy(%{"MAVE_RUNTIME_ROLE" => role})

        assert policy.runtime_role == String.to_existing_atom(role)
        assert policy.start_databases
        refute policy.start_flame_pool
        assert policy.start_oban
        refute policy.run_oban_queues
      end
    end

    test "image nodes run FLAME for cache misses and can enqueue" do
      policy = MaveApplication.runtime_child_policy(%{"MAVE_RUNTIME_ROLE" => "image"})

      assert policy.runtime_role == :image
      assert policy.start_databases
      assert policy.start_flame_pool
      assert policy.start_oban
      refute policy.run_oban_queues
    end

    test "worker nodes run Oban and FLAME" do
      policy = MaveApplication.runtime_child_policy(%{"MAVE_RUNTIME_ROLE" => "worker"})

      assert policy.runtime_role == :worker
      assert policy.start_databases
      assert policy.start_flame_pool
      refute policy.start_flame_prewarmer
      assert policy.start_oban
      assert policy.run_oban_queues
    end

    test "worker nodes can asynchronously prewarm FLAME" do
      policy =
        MaveApplication.runtime_child_policy(%{
          "MAVE_RUNTIME_ROLE" => "worker",
          "MAVE_FLAME_PREWARM_ENABLED" => "true"
        })

      assert policy.runtime_role == :worker
      assert policy.start_flame_pool
      assert policy.start_flame_prewarmer
      assert policy.start_oban
      assert policy.run_oban_queues
    end

    test "ingest nodes can enqueue without running jobs" do
      policy = MaveApplication.runtime_child_policy(%{"MAVE_RUNTIME_ROLE" => "ingest"})

      assert policy.runtime_role == :ingest
      assert policy.start_databases
      refute policy.start_flame_pool
      refute policy.start_flame_prewarmer
      assert policy.start_oban
      refute policy.run_oban_queues
    end

    test "ingest nodes can explicitly opt into FLAME" do
      policy =
        MaveApplication.runtime_child_policy(%{
          "MAVE_RUNTIME_ROLE" => "ingest",
          "MAVE_FLAME_ENABLED" => "true"
        })

      assert policy.start_flame_pool
      assert policy.start_oban
      refute policy.run_oban_queues
    end

    test "FLAME child nodes stay minimal even when role vars are present" do
      policy =
        MaveApplication.runtime_child_policy(%{
          "FLAME_PARENT" => "encoded-parent",
          "MAVE_RUNTIME_ROLE" => "worker",
          "MAVE_FLAME_ENABLED" => "true"
        })

      assert policy.flame_worker
      refute policy.start_cluster_children
      refute policy.start_databases
      refute policy.start_endpoint
      refute policy.start_flame_pool
      refute policy.start_flame_prewarmer
      refute policy.start_oban
      refute policy.run_oban_queues
    end

    test "non-worker Oban config disables queues and plugins" do
      config = [repo: MaveCore.Repo, queues: [default: 10], plugins: [Oban.Plugins.Pruner]]
      policy = MaveApplication.runtime_child_policy(%{"MAVE_RUNTIME_ROLE" => "api"})
      runtime_config = MaveApplication.oban_runtime_config(config, policy)

      assert runtime_config[:repo] == MaveCore.Repo
      assert runtime_config[:queues] == false
      assert runtime_config[:plugins] == false
      assert runtime_config[:peer] == false
    end

    test "worker Oban config keeps queue processing enabled" do
      config = [repo: MaveCore.Repo, queues: [default: 10], plugins: [Oban.Plugins.Pruner]]
      policy = MaveApplication.runtime_child_policy(%{"MAVE_RUNTIME_ROLE" => "worker"})

      assert MaveApplication.oban_runtime_config(config, policy) == config
    end

    test "FLAME prewarmer config supports the legacy single-pool shape" do
      specs =
        MaveApplication.flame_prewarmer_child_specs(
          name: :legacy_prewarmer,
          pool: :image_pool,
          interval_ms: 60_000
        )

      assert specs == [
               {MaveCore.Workers.FlamePrewarmer,
                [name: :legacy_prewarmer, pool: :image_pool, interval_ms: 60_000]}
             ]
    end

    test "FLAME prewarmer config supports multiple named pools" do
      specs =
        MaveApplication.flame_prewarmer_child_specs([
          [name: :image_prewarmer, pool: :image_pool],
          [name: :media_prewarmer, pool: :media_pool]
        ])

      assert specs == [
               {MaveCore.Workers.FlamePrewarmer, [name: :image_prewarmer, pool: :image_pool]},
               {MaveCore.Workers.FlamePrewarmer, [name: :media_prewarmer, pool: :media_pool]}
             ]
    end

    test "FLAME pool defaults allow media jobs to outlive cold starts and short queue waits" do
      options = MaveApplication.flame_pool_options([])

      assert options[:name] == MaveCore.Workers.FlameRunner
      assert options[:timeout] == 30 * 60 * 1000
      assert options[:boot_timeout] == 5 * 60 * 1000
      assert options[:shutdown_timeout] == 5 * 60 * 1000
    end

    test "FLAME pool runtime config can override sizing and timeouts" do
      options =
        MaveApplication.flame_pool_options(
          max: 2,
          timeout: 900_000,
          boot_timeout: 180_000,
          shutdown_timeout: 300_000
        )

      assert options[:name] == MaveCore.Workers.FlameRunner
      assert options[:max] == 2
      assert options[:timeout] == 900_000
      assert options[:boot_timeout] == 180_000
      assert options[:shutdown_timeout] == 300_000
    end

    test "FLAME pool options can target named pools with dedicated backend settings" do
      options =
        MaveApplication.flame_pool_options(
          [
            max: 4,
            timeout: 180_000,
            backend_opts: [pod_generate_name: "flame-image-runner-"]
          ],
          MaveCore.Workers.ImageFlameRunner
        )

      assert options[:name] == MaveCore.Workers.ImageFlameRunner
      assert options[:max] == 4
      assert options[:timeout] == 180_000

      assert options[:backend] ==
               {MaveCore.FLAMEK8sBackend, [pod_generate_name: "flame-image-runner-"]}

      refute Keyword.has_key?(options, :backend_opts)
    end
  end
end
