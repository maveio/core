import Config

postgres_host = System.get_env("POSTGRES_HOST") || "localhost"

postgres_port =
  System.get_env("POSTGRES_PORT") ||
    if postgres_host in ["localhost", "127.0.0.1", "::1"], do: "5433", else: "5432"

# Configure your database
#
# The MIX_TEST_PARTITION environment variable can be used
# to provide built-in test partitioning in CI environment.
# Run `mix help test` for more information.
config :mave_core, MaveCore.Repo,
  username: "postgres",
  password: "postgres",
  hostname: postgres_host,
  port: String.to_integer(postgres_port),
  database: "mave_core_test",
  pool: Ecto.Adapters.SQL.Sandbox,
  pool_size: 10

# We don't run a server during test. If one is required,
# you can enable the server option below.
config :mave_core, MaveCoreWeb.Endpoint,
  http: [ip: {127, 0, 0, 1}, port: 4002],
  secret_key_base: "KSQxa3MJqwaXHPZnVxc7hZ1iuprxl/VsWLTl6FtT250m6EjHif609Qh2ryHpr9ar",
  server: false

# In test we don't send emails
config :mave_core, MaveCore.Mailer, adapter: Swoosh.Adapters.Test

# Disable swoosh api client as it is only required for production adapters
config :swoosh, :api_client, false

config :mave_core, :email_validation, checker: MaveCore.TestSupport.EmailCheckerStub
config :mave_core, :storage_module, MaveCore.TestSupport.FlowStorageAdapterStub
config :mave_core, :shared_storage_space_hash, "trial"

# Print only warnings and errors during test
config :logger, level: :warning

# Initialize plugs at runtime for faster test compilation
config :phoenix, :plug_init_mode, :runtime

# Enable helpful, but potentially expensive runtime checks
config :phoenix_live_view,
  enable_expensive_runtime_checks: true

config :phoenix_live_view, :test_warnings, missing_form_id: :raise

# Sort query params output of verified routes for robust url comparisons
config :mave_core, MaveCore.ClickHouseRepo,
  hostname: System.get_env("CLICKHOUSE_HOST") || "localhost",
  port: 8123,
  database: "mave_metrics_test",
  username: "default",
  password: "password",
  scheme: "http",
  pool_size: 5,
  settings: [async_insert: 0, wait_for_async_insert: 1],
  priv: "priv/clickhouse_repo"

config :mave_core, :s3,
  access_key_id: System.get_env("AWS_ACCESS_KEY_ID") || "minioadmin",
  secret_access_key: System.get_env("AWS_SECRET_ACCESS_KEY") || "minioadmin",
  endpoint: System.get_env("S3_ENDPOINT") || "http://localhost:9000",
  region: System.get_env("AWS_REGION") || "us-east-1"

config :mave_core, :internal_secret, System.get_env("MAVE_CORE_INTERNAL_SECRET") || "test_secret"

config :mave_core, Oban,
  repo: MaveCore.Repo,
  plugins: false,
  queues: false,
  testing: :inline
