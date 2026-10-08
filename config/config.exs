# This file is responsible for configuring your application
# and its dependencies with the aid of the Config module.
#
# This configuration file is loaded before any dependency and
# is restricted to this project.

# General application configuration
import Config

config :phoenix,
       :filter_parameters,
       ~w(password token secret authorization credential signature api_key input_url source_url code)

config :mave_core,
  ecto_repos: [MaveCore.Repo, MaveCore.ClickHouseRepo],
  generators: [timestamp_type: :utc_datetime]

# Configure the endpoint
config :mave_core, MaveCoreWeb.Endpoint,
  url: [host: "localhost"],
  adapter: Bandit.PhoenixAdapter,
  render_errors: [
    formats: [html: MaveCoreWeb.ErrorHTML, json: MaveCoreWeb.ErrorJSON],
    layout: false
  ],
  pubsub_server: MaveCore.PubSub,
  live_view: [signing_salt: "yvwmrrwZ"]

config :flame, :backend, FLAME.LocalBackend
config :flame, FLAME.LocalBackend, terminator_interval: :timer.hours(1)

config :mave_core, Oban,
  repo: MaveCore.Repo,
  plugins: [
    {Oban.Plugins.Pruner, max_age: 7 * 24 * 60 * 60},
    {Oban.Plugins.Lifeline, rescue_after: :timer.hours(7)},
    {Oban.Plugins.Cron,
     crontab: [
       {"* * * * *", MaveCore.Workers.FlowRecoveryWorker},
       {"23 * * * *", MaveCore.Workers.CliAuthorizationPruneWorker}
     ]}
  ],
  shutdown_grace_period: :timer.hours(6),
  queues: [
    flow_coordinator: 20,
    flow_steps: 50,
    flow_booster: 50,
    flow_booster_background: 38,
    flow_media: 10,
    flow_imports: 10,
    flow_low: 5,
    webhooks: 20
  ]

config :mave_core, :flow_fair_queues,
  flow_steps: [
    space_concurrency: 1,
    global_concurrency: 50,
    new_space_headroom: 5,
    work_conserving: true,
    snooze_seconds: 1
  ],
  flow_booster: [
    space_concurrency: 6,
    global_concurrency: 50,
    new_space_headroom: 5,
    work_conserving: true,
    capacity_snooze_seconds: 5,
    snooze_seconds: 1
  ],
  flow_booster_background: [
    space_concurrency: 2,
    run_concurrency: 6,
    global_concurrency: 50,
    background_concurrency: 38,
    background_concurrency_when_foreground_waiting: 0,
    new_space_headroom: 4,
    work_conserving: true,
    capacity_snooze_seconds: 5,
    snooze_seconds: 1
  ],
  flow_media: [space_concurrency: 8, snooze_seconds: 1],
  flow_imports: [space_concurrency: 2, snooze_seconds: 10],
  flow_low: [
    space_concurrency: 1,
    global_concurrency: 5,
    new_space_headroom: 1,
    work_conserving: true,
    snooze_seconds: 1
  ]

config :mave_core, :flow_stale_step_recovery,
  enabled: true,
  older_than_ms: 5 * 60 * 1000,
  limit: 25

config :mave_core, MaveCore.Media.ImageGenerationCache,
  primary: [
    gc_interval: :timer.hours(1)
  ]

config :mave_core, :email_validation, checker: EmailChecker
config :mave_core, :google_oauth_enabled, false
config :mave_core, :shared_storage_space_hash, nil
config :mave_core, :signup_policy, terms_required: false, product_name: "Mave Core"
config :mave_core, :public_registration, enabled: false, max_users: 100

config :ueberauth, Ueberauth,
  providers: [
    google: {Ueberauth.Strategy.Google, []}
  ]

config :ueberauth, Ueberauth.Strategy.Google.OAuth,
  client_id: System.get_env("GOOGLE_CLIENT_ID"),
  client_secret: System.get_env("GOOGLE_CLIENT_SECRET")

config :ua_inspector,
  downloader_adapter: MaveCore.UAInspectorDownloader,
  database_path:
    System.get_env("UA_INSPECTOR_DATABASE_PATH") || Path.join(File.cwd!(), "priv/ua_inspector")

config :mave_core, :upload,
  endpoint: "http://localhost:1080/files",
  bucket: "mave-upload",
  source_base_url: "http://localhost:9000",
  public_base_url: nil,
  source_region: "us-east-1",
  hook_secret: nil,
  default_template: "publish_default"

config :mave_core, :media_input, max_bytes: 20 * 1024 * 1024 * 1024

config :mave_core,
  public_cdn_scheme: "https",
  public_cdn_host: "video-dns.com",
  components_base_url: nil,
  components_src: nil,
  image_base_url: "https://image.mave.io"

config :mave_core, :logged_in_marker_cookie, enabled: false

config :mave_core, :flow_admin,
  emails: [],
  email_domains: []

config :mave_core, :flow_step_auto_retry,
  max_attempts: 3,
  backoff_seconds: [10, 30],
  booster_gateway_max_attempts: 5,
  booster_gateway_backoff_seconds: [10, 30, 60, 120],
  jitter_seconds: 5

config :mave_core, :flow_step_retry_policy,
  max_execution_attempts: 3,
  max_orphan_recoveries: 1

config :mave_core, :flow_direct_storage_ffmpeg_input, true

config :mave_core, :encoding_booster,
  enabled: false,
  endpoint: nil,
  iam_secret_key: nil,
  fallback_enabled: true,
  chunking_threshold_seconds: 900,
  chunk_duration_seconds: 600,
  connect_timeout_ms: 10_000,
  receive_timeout_ms: :timer.hours(1),
  retry_backoff_ms: [1_000, 2_000, 4_000, 8_000, 15_000],
  retry_jitter_ms: 500

config :mave_core, :gpu_encoding_booster,
  enabled: false,
  endpoint: nil,
  bearer_token: nil,
  fallback_enabled: true,
  connect_timeout_ms: 10_000,
  receive_timeout_ms: :timer.hours(1),
  retry_backoff_ms: [1_000, 2_000, 4_000, 8_000, 15_000],
  retry_jitter_ms: 500

config :mave_core, :extra_dashboard_items, [
  %{
    id: :flow,
    label: "Flow",
    path: "/flow/runs",
    placement: :menu,
    visible?: false
  }
]

# Configure the mailer
#
# By default it uses the "Local" adapter which stores the emails
# locally. You can see the emails in your browser, at "/dev/mailbox".
#
# For production it's recommended to configure a different adapter
# at the `config/runtime.exs`.
config :mave_core, MaveCore.Mailer, adapter: Swoosh.Adapters.Local

# Configure esbuild (the version is required)
js_entrypoints =
  if config_env() in [:dev, :test], do: ~w(js/app.js js/storybook.js), else: ~w(js/app.js)

config :esbuild,
  version: "0.25.4",
  mave_core: [
    args:
      js_entrypoints ++
        ~w(--bundle --target=es2022 --outdir=../priv/static/assets/js --external:/fonts/* --external:/images/* --alias:@=.),
    cd: Path.expand("../assets", __DIR__),
    env: %{"NODE_PATH" => [Path.expand("../deps", __DIR__), Mix.Project.build_path()]}
  ]

# Configure tailwind (the version is required)
config :tailwind,
  version: "4.1.12",
  mave_core: [
    args: ~w(
      --input=assets/css/app.css
      --output=priv/static/assets/css/app.css
    ),
    cd: Path.expand("..", __DIR__)
  ],
  storybook: [
    args: ~w(
      --input=assets/css/storybook.css
      --output=priv/static/assets/css/storybook.css
    ),
    cd: Path.expand("..", __DIR__)
  ]

config :mave_core, MaveCore.ClickHouseRepo,
  hostname: "localhost",
  port: 8123,
  scheme: "http",
  database: "mave_metrics",
  settings: [async_insert: 1, wait_for_async_insert: 0],
  priv: "priv/clickhouse_repo",
  migrations_path: "priv/clickhouse_repo/migrations"

# Configure Elixir's Logger
config :logger, :default_formatter,
  format: "$time $metadata[$level] $message\n",
  metadata: [:request_id]

# Use Jason for JSON parsing in Phoenix
config :phoenix, :json_library, Jason

config :mime, :types, %{
  "text/vtt" => ["vtt"]
}

# Import environment specific config. This must remain at the bottom
# of this file so it overrides the configuration defined above.
import_config "#{config_env()}.exs"
