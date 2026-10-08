defmodule MaveCore.MixProject do
  use Mix.Project

  def project do
    [
      app: :mave_core,
      version: "0.1.0",
      elixir: "~> 1.15",
      elixirc_paths: elixirc_paths(Mix.env()),
      start_permanent: Mix.env() == :prod,
      aliases: aliases(),
      deps: deps(),
      compilers: [:phoenix_live_view] ++ Mix.compilers(),
      listeners: [Phoenix.CodeReloader]
    ]
  end

  # Configuration for the OTP application.
  #
  # Type `mix help compile.app` for more information.
  def application do
    [
      mod: {MaveCore.Application, []},
      extra_applications: [:logger, :runtime_tools]
    ]
  end

  def cli do
    [
      preferred_envs: [
        audit: :test,
        coverage: :test,
        lint: :test,
        precommit: :test,
        security: :test,
        "security.enforce": :test,
        test: :test
      ]
    ]
  end

  # Specifies which paths to compile per environment.
  defp elixirc_paths(:test), do: ["lib", "test/support"]
  defp elixirc_paths(_), do: ["lib"]

  # Specifies your project dependencies.
  #
  # Type `mix help deps` for examples and options.
  defp deps do
    [
      {:phoenix, "~> 1.8.3"},
      {:phoenix_ecto, "~> 4.5"},
      {:ecto_sql, "~> 3.13"},
      {:postgrex, "~> 0.22.3"},
      {:decimal, "~> 3.1", override: true},
      {:phoenix_html, "~> 4.1"},
      {:phoenix_live_reload, "~> 1.2", only: :dev},
      {:phoenix_live_view, "~> 1.2.9"},
      {:lazy_html, ">= 0.1.13", only: :test},
      {:phoenix_live_dashboard, "~> 0.8.3"},
      {:esbuild, "~> 0.10", runtime: Mix.env() == :dev},
      {:tailwind, "~> 0.3", runtime: Mix.env() == :dev},
      {:heroicons,
       github: "tailwindlabs/heroicons",
       tag: "v2.2.0",
       sparse: "optimized",
       app: false,
       compile: false,
       depth: 1},
      {:swoosh, "~> 1.27"},
      {:gen_smtp, "~> 1.3"},
      {:req, "~> 0.7"},
      # Finch 0.24 closes abandoned HTTP/1 connections with Mint 1.11.
      {:finch, "~> 0.24.0"},
      # Keep consuming applications above the patched HTTP/1 and HTTP/2 baseline.
      {:mint, ">= 1.11.0 and < 2.0.0"},
      {:req_s3, "~> 0.2.5"},
      {:telemetry_metrics, "~> 1.0"},
      {:telemetry_poller, "~> 1.0"},
      {:gettext, "~> 1.0"},
      {:jason, "~> 1.2"},
      {:dns_cluster, "~> 0.2.0"},
      {:bandit, "~> 1.12.5"},
      {:flame_k8s_backend, "~> 0.5.7"},
      {:ch, "~> 0.8.3"},
      {:broadway, "~> 1.0"},
      {:ua_inspector, "~> 3.12"},
      {:ecto_ch, "~> 0.10.0"},
      {:hammer, "~> 7.1"},
      {:nebulex_distributed, "~> 3.0"},
      {:cors_plug, "~> 3.0"},
      {:phoenix_storybook, "~> 1.3", only: [:dev, :test]},
      {:hackney, "~> 4.7", override: true},
      {:credo, "~> 1.7", only: [:dev, :test], runtime: false},
      {:mix_audit, "~> 2.1", only: [:dev, :test], runtime: false},
      {:sobelow, "~> 0.14", only: [:dev, :test], runtime: false},
      {:oban, "~> 2.18"},
      {:email_checker, "~> 0.2.4"},
      {:oauth2, "~> 2.1.1"},
      {:joken, "~> 2.6"},
      {:ueberauth, "~> 0.10.8"},
      {:ueberauth_google, "~> 0.12.1"},
      {:whatlangex, "~> 0.4.0"}
    ]
  end

  # Aliases are shortcuts or tasks specific to the current project.
  # For example, to install project dependencies and perform other setup tasks, run:
  #
  #     $ mix setup
  #
  # See the documentation for `Mix` for more info on aliases.
  defp aliases do
    [
      setup: [
        "deps.get",
        "ua_inspector.download --force",
        "assets.setup",
        "assets.build",
        "run priv/repo/seeds.exs"
      ],
      test: [
        "clickhouse.ensure_test_db",
        "ecto.create --quiet -r MaveCore.Repo -r MaveCore.ClickHouseRepo",
        "ecto.migrate --quiet -r MaveCore.Repo -r MaveCore.ClickHouseRepo",
        "test"
      ],
      "assets.setup": [
        "tailwind.install --if-missing",
        "esbuild.install --if-missing",
        "cmd --cd assets npm ci"
      ],
      "assets.build": ["compile", "tailwind mave_core", "esbuild mave_core"],
      "assets.deploy": [
        "tailwind mave_core --minify",
        "esbuild mave_core --minify",
        "phx.digest"
      ],
      audit: [
        "compile --warnings-as-errors",
        "xref graph --format stats --label compile-connected"
      ],
      coverage: ["test --cover"],
      security: [
        "hex.audit",
        "sobelow --skip --private --compact --ignore Config.CSWH,Config.CSP,Config.CSRF",
        "deps.audit"
      ],
      "security.enforce": [
        "hex.audit",
        "sobelow --skip --private --compact --ignore Config.CSWH,Config.CSP,Config.CSRF --exit --threshold medium",
        "deps.audit"
      ],
      lint: ["audit", "credo --strict", "security"],
      precommit: ["deps.unlock --unused", "format", "audit"]
    ]
  end
end
