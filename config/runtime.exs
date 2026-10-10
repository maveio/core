import Config

# config/runtime.exs is executed for all environments, including
# during releases. It is executed after compilation and before the
# system starts, so it is typically used to load production configuration
# and secrets from environment variables or elsewhere. Do not define
# any compile-time configuration in here, as it won't be applied.
# The block below contains prod specific runtime configuration.

# ## Using releases
#
# If you use `mix release`, you need to explicitly enable the server
# by passing the PHX_SERVER=true when you start it:
#
#     PHX_SERVER=true bin/mave_core start
#
# Alternatively, you can use `mix phx.gen.release` to generate a `bin/server`
# script that automatically sets the env var above.
if System.get_env("PHX_SERVER") do
  config :mave_core, MaveCoreWeb.Endpoint, server: true
end

parse_csv_env = fn env_name ->
  env_name
  |> System.get_env()
  |> case do
    nil ->
      []

    value ->
      value
      |> String.split(",", trim: true)
      |> Enum.map(&String.trim/1)
      |> Enum.reject(&(&1 == ""))
  end
end

parse_integer_env = fn env_name, default ->
  case System.get_env(env_name) do
    nil ->
      default

    value ->
      case Integer.parse(value) do
        {parsed, ""} -> parsed
        _ -> raise "#{env_name} must be an integer, got: #{inspect(value)}"
      end
  end
end

parse_non_negative_integer_csv_env = fn env_name, default ->
  case System.get_env(env_name) do
    nil ->
      default

    value ->
      values =
        value
        |> String.split(",", trim: true)
        |> Enum.map(&String.trim/1)
        |> Enum.reject(&(&1 == ""))
        |> Enum.map(fn item ->
          case Integer.parse(item) do
            {parsed, ""} when parsed >= 0 -> parsed
            _other -> raise "#{env_name} must contain comma-separated non-negative integers"
          end
        end)

      if values == [], do: default, else: values
  end
end

parse_boolean_env = fn env_name, default ->
  case System.get_env(env_name) do
    nil ->
      default

    value when value in ["true", "1", "TRUE"] ->
      true

    value when value in ["false", "0", "FALSE"] ->
      false

    value ->
      raise "#{env_name} must be a boolean, got: #{inspect(value)}"
  end
end

config :mave_core, :installation_setup,
  enabled: parse_boolean_env.("MAVE_INSTALLATION_SETUP", false),
  code_file: System.get_env("MAVE_SETUP_CODE_FILE", "/setup/code")

parse_string_env = fn env_name, default ->
  case System.get_env(env_name) do
    nil -> default
    value -> String.trim(value)
  end
end

parse_optional_string_env = fn env_name ->
  case System.get_env(env_name) do
    value when is_binary(value) ->
      case String.trim(value) do
        "" -> nil
        trimmed -> trimmed
      end

    _other ->
      nil
  end
end

config :mave_core, MaveCoreWeb.Endpoint,
  http: [port: String.to_integer(System.get_env("PORT", "4000"))]

external_uri =
  case System.get_env("MAVE_DOMAIN") do
    nil ->
      nil

    value ->
      uri = value |> String.trim() |> URI.parse()

      if uri.scheme in ["http", "https"] and is_binary(uri.host) and uri.host != "" and
           uri.path in [nil, "", "/"] and is_nil(uri.userinfo) and is_nil(uri.query) and
           is_nil(uri.fragment) do
        uri
      else
        raise "MAVE_DOMAIN must be an HTTP(S) origin without a path, query, or fragment"
      end
  end

if external_uri do
  config :mave_core,
         :domain,
         external_uri
         |> Map.put(:path, nil)
         |> URI.to_string()
         |> String.trim_trailing("/")
end

# Optional per-space media origin; an unset value retains the API playback route.
if playback_origin = System.get_env("MAVE_PLAYBACK_ORIGIN") do
  uri = playback_origin |> String.trim() |> URI.parse()

  unless uri.scheme in ["http", "https"] and is_binary(uri.host) and uri.host != "" and
           uri.path in [nil, "", "/"] and is_nil(uri.query) and is_nil(uri.fragment) and
           is_nil(uri.userinfo) do
    raise "MAVE_PLAYBACK_ORIGIN must be an HTTP(S) origin without a path or credentials"
  end

  config :mave_core,
         :playback_origin,
         URI.to_string(%{uri | host: String.downcase(uri.host), path: nil})
end

if public_cdn_host = System.get_env("MAVE_PUBLIC_CDN_HOST") do
  trimmed = String.trim(public_cdn_host)

  if trimmed != "" do
    config :mave_core, :public_cdn_host, trimmed
  end
end

if public_cdn_base_url = System.get_env("MAVE_PUBLIC_CDN_BASE_URL") do
  trimmed = public_cdn_base_url |> String.trim() |> String.trim_trailing("/")

  case URI.parse(trimmed) do
    %URI{scheme: scheme, host: host, userinfo: nil, query: nil, fragment: nil}
    when scheme in ["http", "https"] and is_binary(host) and host != "" ->
      config :mave_core, :public_cdn_base_url, trimmed

    _other ->
      raise "MAVE_PUBLIC_CDN_BASE_URL must be an HTTP(S) base URL"
  end
end

if public_cdn_scheme = System.get_env("MAVE_PUBLIC_CDN_SCHEME") do
  trimmed = String.trim(public_cdn_scheme)

  if trimmed != "" do
    config :mave_core, :public_cdn_scheme, trimmed
  end
end

if public_cdn_mode = System.get_env("MAVE_PUBLIC_CDN_MODE") do
  trimmed =
    public_cdn_mode
    |> String.trim()
    |> String.downcase()

  if trimmed in ["path", "subdomain", "direct_s3"] do
    config :mave_core, :public_cdn_mode, trimmed
  end
end

if components_src = System.get_env("MAVE_COMPONENTS_SRC") do
  trimmed = String.trim(components_src)

  if trimmed != "" do
    config :mave_core, :components_src, trimmed
  end
end

if components_base_url = System.get_env("MAVE_COMPONENTS_BASE_URL") do
  trimmed = String.trim(components_base_url)

  if trimmed != "" do
    config :mave_core, :components_base_url, String.trim_trailing(trimmed, "/")
  end
end

if image_base_url = System.get_env("MAVE_IMAGE_BASE_URL") do
  trimmed = String.trim(image_base_url)

  if trimmed != "" do
    config :mave_core, :image_base_url, String.trim_trailing(trimmed, "/")
  end
end

config :mave_core,
       :default_storage_profile,
       parse_string_env.("MAVE_DEFAULT_STORAGE_PROFILE", "default")

if shared_storage_space_hash = parse_optional_string_env.("MAVE_SHARED_STORAGE_SPACE_HASH") do
  config :mave_core, :shared_storage_space_hash, shared_storage_space_hash
end

config :mave_core,
       :email_from,
       {parse_string_env.("MAVE_EMAIL_FROM_NAME", "Mave Core"),
        parse_string_env.("MAVE_EMAIL_FROM_ADDRESS", "noreply@localhost")}

config :mave_core,
       :google_oauth_enabled,
       parse_boolean_env.("MAVE_GOOGLE_OAUTH_ENABLED", false)

public_registration_default = config_env() in [:dev, :test]

config :mave_core, :public_registration,
  enabled: parse_boolean_env.("MAVE_PUBLIC_REGISTRATION_ENABLED", public_registration_default),
  max_users: parse_integer_env.("MAVE_PUBLIC_REGISTRATION_MAX_USERS", 100)

config :ueberauth, Ueberauth.Strategy.Google.OAuth,
  client_id: System.get_env("GOOGLE_CLIENT_ID"),
  client_secret: System.get_env("GOOGLE_CLIENT_SECRET")

internal_secret =
  case {config_env(), System.get_env("MAVE_CORE_INTERNAL_SECRET")} do
    {:prod, nil} ->
      raise("MAVE_CORE_INTERNAL_SECRET is missing")

    {_env, nil} ->
      "dev_local_secret"

    {_env, value} ->
      if String.trim(value) == "", do: raise("MAVE_CORE_INTERNAL_SECRET must not be blank")
      value
  end

config :mave_core, internal_secret: internal_secret

upload_hook_secret = System.get_env("MAVE_UPLOAD_HOOK_SECRET") || internal_secret

if String.trim(upload_hook_secret) == "" do
  raise "MAVE_UPLOAD_HOOK_SECRET must not be blank"
end

flow_admin_emails = parse_csv_env.("MAVE_FLOW_ADMIN_EMAILS")
flow_admin_email_domains = parse_csv_env.("MAVE_FLOW_ADMIN_EMAIL_DOMAINS")

if flow_admin_emails != [] or flow_admin_email_domains != [] do
  config :mave_core, :flow_admin,
    emails: flow_admin_emails,
    email_domains: flow_admin_email_domains
end

default_upload_template =
  System.get_env("MAVE_UPLOAD_TEMPLATE") ||
    if config_env() == :dev, do: "publish_local", else: "publish_default"

upload_source_base_url =
  System.get_env("MAVE_UPLOAD_SOURCE_BASE_URL") ||
    System.get_env("S3_ENDPOINT") ||
    "http://localhost:9000"

config :mave_core, :upload,
  endpoint: System.get_env("MAVE_UPLOAD_ENDPOINT") || "http://localhost:1080/files",
  bucket: System.get_env("MAVE_UPLOAD_BUCKET") || "mave-upload",
  source_base_url: upload_source_base_url,
  public_base_url: System.get_env("MAVE_UPLOAD_PUBLIC_BASE_URL"),
  source_region:
    System.get_env("MAVE_UPLOAD_SOURCE_REGION") ||
      System.get_env("S3_REGION") ||
      System.get_env("AWS_REGION") ||
      "us-east-1",
  object_acl: parse_boolean_env.("MAVE_UPLOAD_OBJECT_ACL", false),
  hook_secret: upload_hook_secret,
  default_template: default_upload_template

media_input_max_bytes =
  parse_integer_env.("MAVE_MEDIA_INPUT_MAX_BYTES", 20 * 1024 * 1024 * 1024)

if media_input_max_bytes <= 0 do
  raise "MAVE_MEDIA_INPUT_MAX_BYTES must be a positive integer"
end

config :mave_core, :media_input, max_bytes: media_input_max_bytes

if config_env() == :prod do
  runtime_role = System.get_env("MAVE_RUNTIME_ROLE")
  worker_runtime? = runtime_role in ["worker", "web", nil]

  config :mave_core, :image_generation_budget,
    per_minute: parse_integer_env.("MAVE_IMAGE_GENERATION_LIMIT_PER_MINUTE", 20),
    per_day: parse_integer_env.("MAVE_IMAGE_GENERATION_LIMIT_PER_DAY", 200)

  config :mave_core, :image_variant_budget,
    per_embed: parse_integer_env.("MAVE_IMAGE_VARIANT_LIMIT_PER_EMBED", 1_000),
    per_space: parse_integer_env.("MAVE_IMAGE_VARIANT_LIMIT_PER_SPACE", 10_000),
    per_installation: parse_integer_env.("MAVE_IMAGE_VARIANT_LIMIT_PER_INSTALLATION", 50_000)

  database_url =
    System.get_env("DATABASE_URL") ||
      raise """
      environment variable DATABASE_URL is missing.
      For example: ecto://USER:PASS@HOST/DATABASE
      """

  maybe_ipv6 = if System.get_env("ECTO_IPV6") in ~w(true 1), do: [:inet6], else: []
  repo_pool_size = parse_integer_env.("POOL_SIZE", 2)

  worker_queue_limit = fn fallback, floor, ceiling, divisor ->
    if worker_runtime?,
      do: repo_pool_size |> div(divisor) |> max(floor) |> min(ceiling),
      else: fallback
  end

  repo_queue_target_ms =
    if worker_runtime?,
      do: parse_integer_env.("ECTO_QUEUE_TARGET_MS", 5_000),
      else: parse_integer_env.("ECTO_QUEUE_TARGET_MS", 50)

  repo_queue_interval_ms =
    if worker_runtime?,
      do: parse_integer_env.("ECTO_QUEUE_INTERVAL_MS", 10_000),
      else: parse_integer_env.("ECTO_QUEUE_INTERVAL_MS", 1_000)

  config :mave_core, MaveCore.Repo,
    # ssl: true,
    url: database_url,
    pool_size: repo_pool_size,
    queue_target: repo_queue_target_ms,
    queue_interval: repo_queue_interval_ms,
    # For machines with several cores, consider starting multiple pools of `pool_size`
    # pool_count: 4,
    socket_options: maybe_ipv6

  flow_coordinator_limit =
    parse_integer_env.(
      "MAVE_OBAN_FLOW_COORDINATOR_LIMIT",
      worker_queue_limit.(20, 2, 4, 6)
    )

  flow_steps_limit =
    parse_integer_env.("MAVE_OBAN_FLOW_STEPS_LIMIT", worker_queue_limit.(50, 2, 8, 3))

  flow_media_limit =
    parse_integer_env.("MAVE_OBAN_FLOW_MEDIA_LIMIT", worker_queue_limit.(10, 1, 4, 4))

  flow_booster_limit =
    parse_integer_env.("MAVE_OBAN_FLOW_BOOSTER_LIMIT", 50)

  flow_booster_background_limit =
    parse_integer_env.("MAVE_OBAN_FLOW_BOOSTER_BACKGROUND_LIMIT", 38)

  flow_booster_background_run_limit =
    parse_integer_env.("MAVE_FLOW_BOOSTER_BACKGROUND_RUN_CONCURRENCY", 6)

  flow_imports_limit =
    parse_integer_env.("MAVE_OBAN_FLOW_IMPORTS_LIMIT", worker_queue_limit.(10, 1, 3, 8))

  flow_low_limit =
    parse_integer_env.("MAVE_OBAN_FLOW_LOW_LIMIT", worker_queue_limit.(5, 1, 2, 4))

  webhooks_limit =
    parse_integer_env.("MAVE_OBAN_WEBHOOKS_LIMIT", worker_queue_limit.(20, 1, 4, 6))

  queue_headroom = fn capacity -> max(1, div(capacity + 9, 10)) end

  config :mave_core, Oban,
    queues: [
      flow_coordinator: flow_coordinator_limit,
      flow_steps: flow_steps_limit,
      flow_booster: flow_booster_limit,
      flow_booster_background: flow_booster_background_limit,
      flow_media: flow_media_limit,
      flow_imports: flow_imports_limit,
      flow_low: flow_low_limit,
      webhooks: webhooks_limit
    ]

  config :mave_core, :flow_fair_queues,
    flow_steps: [
      space_concurrency: 1,
      global_concurrency: flow_steps_limit,
      new_space_headroom: queue_headroom.(flow_steps_limit),
      work_conserving: true,
      snooze_seconds: 1
    ],
    flow_booster: [
      space_concurrency: 6,
      global_concurrency: flow_booster_limit,
      new_space_headroom: queue_headroom.(flow_booster_limit),
      work_conserving: true,
      capacity_snooze_seconds: 5,
      snooze_seconds: 1
    ],
    flow_booster_background: [
      space_concurrency: 2,
      run_concurrency: flow_booster_background_run_limit,
      global_concurrency: flow_booster_limit,
      background_concurrency: flow_booster_background_limit,
      background_concurrency_when_foreground_waiting: 0,
      new_space_headroom: queue_headroom.(flow_booster_background_limit),
      work_conserving: true,
      capacity_snooze_seconds: 5,
      snooze_seconds: 1
    ],
    flow_media: [space_concurrency: 8, snooze_seconds: 1],
    flow_imports: [space_concurrency: 2, snooze_seconds: 10],
    flow_low: [
      space_concurrency: 1,
      global_concurrency: flow_low_limit,
      new_space_headroom: queue_headroom.(flow_low_limit),
      work_conserving: true,
      snooze_seconds: 1
    ]

  config :mave_core, :flow_stale_step_recovery,
    enabled: parse_boolean_env.("MAVE_FLOW_STALE_STEP_RECOVERY_ENABLED", true),
    older_than_ms: parse_integer_env.("MAVE_FLOW_STALE_STEP_RECOVERY_AFTER_MS", 5 * 60 * 1000),
    limit: parse_integer_env.("MAVE_FLOW_STALE_STEP_RECOVERY_LIMIT", 25)

  config :mave_core, :flow_step_retry_policy,
    max_execution_attempts: parse_integer_env.("MAVE_FLOW_STEP_MAX_EXECUTION_ATTEMPTS", 3),
    max_orphan_recoveries: parse_integer_env.("MAVE_FLOW_STEP_MAX_ORPHAN_RECOVERIES", 1)

  config :mave_core, MaveCoreWeb.Plugs.EventIngestRateLimit,
    interval_ms: parse_integer_env.("MAVE_EVENT_INGEST_RATE_LIMIT_INTERVAL_MS", 60_000),
    max_requests: parse_integer_env.("MAVE_EVENT_INGEST_RATE_LIMIT_MAX_REQUESTS", 120),
    trusted_proxy_cidrs: parse_csv_env.("MAVE_TRUSTED_PROXY_CIDRS")

  config :mave_core,
         :flow_direct_storage_ffmpeg_input,
         parse_boolean_env.("MAVE_FLOW_DIRECT_STORAGE_FFMPEG_INPUT", false)

  encoding_booster_enabled = parse_boolean_env.("MAVE_ENCODING_BOOSTER_ENABLED", false)
  encoding_booster_endpoint = parse_string_env.("MAVE_ENCODING_BOOSTER_ENDPOINT", nil)

  encoding_booster_iam_secret_key =
    parse_string_env.("MAVE_ENCODING_BOOSTER_IAM_SECRET_KEY", nil)

  if encoding_booster_enabled and
       (encoding_booster_endpoint in [nil, ""] or encoding_booster_iam_secret_key in [nil, ""]) do
    raise """
    MAVE_ENCODING_BOOSTER_ENDPOINT and MAVE_ENCODING_BOOSTER_IAM_SECRET_KEY are
    required when MAVE_ENCODING_BOOSTER_ENABLED is true
    """
  end

  if encoding_booster_enabled do
    case URI.parse(encoding_booster_endpoint) do
      %URI{scheme: "https", host: host, userinfo: nil, query: nil, fragment: nil}
      when is_binary(host) and host != "" ->
        :ok

      _ ->
        raise "MAVE_ENCODING_BOOSTER_ENDPOINT must be an HTTPS base URL"
    end
  end

  config :mave_core, :encoding_booster,
    enabled: encoding_booster_enabled,
    endpoint: encoding_booster_endpoint,
    iam_secret_key: encoding_booster_iam_secret_key,
    fallback_enabled: parse_boolean_env.("MAVE_ENCODING_BOOSTER_FALLBACK_ENABLED", true),
    chunking_threshold_seconds:
      parse_integer_env.("MAVE_ENCODING_BOOSTER_CHUNKING_THRESHOLD_SECONDS", 900),
    chunk_duration_seconds:
      parse_integer_env.("MAVE_ENCODING_BOOSTER_CHUNK_DURATION_SECONDS", 600),
    readiness_check_enabled:
      parse_boolean_env.("MAVE_ENCODING_BOOSTER_READINESS_CHECK_ENABLED", false),
    readiness_timeout_ms: parse_integer_env.("MAVE_ENCODING_BOOSTER_READINESS_TIMEOUT_MS", 1_000),
    warmup_requests: parse_integer_env.("MAVE_ENCODING_BOOSTER_WARMUP_REQUESTS", 12),
    warmup_hold_ms: parse_integer_env.("MAVE_ENCODING_BOOSTER_WARMUP_HOLD_MS", 15_000),
    connect_timeout_ms: parse_integer_env.("MAVE_ENCODING_BOOSTER_CONNECT_TIMEOUT_MS", 10_000),
    receive_timeout_ms:
      parse_integer_env.("MAVE_ENCODING_BOOSTER_RECEIVE_TIMEOUT_MS", 60 * 60 * 1000),
    retry_backoff_ms:
      parse_non_negative_integer_csv_env.(
        "MAVE_ENCODING_BOOSTER_RETRY_BACKOFF_MS",
        [1_000, 2_000, 4_000, 8_000, 15_000]
      ),
    busy_retry_backoff_ms:
      parse_non_negative_integer_csv_env.(
        "MAVE_ENCODING_BOOSTER_BUSY_RETRY_BACKOFF_MS",
        [250, 500, 1_000, 2_000, 4_000]
      ),
    retry_jitter_ms: parse_integer_env.("MAVE_ENCODING_BOOSTER_RETRY_JITTER_MS", 500)

  gpu_encoding_booster_enabled =
    parse_boolean_env.("MAVE_GPU_ENCODING_BOOSTER_ENABLED", false)

  gpu_encoding_booster_endpoint =
    parse_string_env.("MAVE_GPU_ENCODING_BOOSTER_ENDPOINT", nil)

  gpu_encoding_booster_bearer_token =
    parse_string_env.("MAVE_GPU_ENCODING_BOOSTER_BEARER_TOKEN", nil)

  if gpu_encoding_booster_enabled and
       (gpu_encoding_booster_endpoint in [nil, ""] or
          gpu_encoding_booster_bearer_token in [nil, ""]) do
    raise """
    MAVE_GPU_ENCODING_BOOSTER_ENDPOINT and
    MAVE_GPU_ENCODING_BOOSTER_BEARER_TOKEN are required when
    MAVE_GPU_ENCODING_BOOSTER_ENABLED is true
    """
  end

  if gpu_encoding_booster_enabled do
    case URI.parse(gpu_encoding_booster_endpoint) do
      %URI{scheme: "http", host: host, userinfo: nil, query: nil, fragment: nil}
      when is_binary(host) and host != "" ->
        :ok

      _other ->
        raise "MAVE_GPU_ENCODING_BOOSTER_ENDPOINT must be a private HTTP base URL"
    end
  end

  config :mave_core, :gpu_encoding_booster,
    enabled: gpu_encoding_booster_enabled,
    endpoint: gpu_encoding_booster_endpoint,
    bearer_token: gpu_encoding_booster_bearer_token,
    fallback_enabled: parse_boolean_env.("MAVE_GPU_ENCODING_BOOSTER_FALLBACK_ENABLED", true),
    readiness_check_enabled:
      parse_boolean_env.("MAVE_GPU_ENCODING_BOOSTER_READINESS_CHECK_ENABLED", true),
    readiness_timeout_ms:
      parse_integer_env.("MAVE_GPU_ENCODING_BOOSTER_READINESS_TIMEOUT_MS", 1_000),
    warmup_requests: parse_integer_env.("MAVE_GPU_ENCODING_BOOSTER_WARMUP_REQUESTS", 1),
    connect_timeout_ms:
      parse_integer_env.("MAVE_GPU_ENCODING_BOOSTER_CONNECT_TIMEOUT_MS", 10_000),
    receive_timeout_ms:
      parse_integer_env.("MAVE_GPU_ENCODING_BOOSTER_RECEIVE_TIMEOUT_MS", 60 * 60 * 1000),
    retry_backoff_ms:
      parse_non_negative_integer_csv_env.(
        "MAVE_GPU_ENCODING_BOOSTER_RETRY_BACKOFF_MS",
        [1_000, 2_000, 4_000, 8_000, 15_000]
      ),
    retry_jitter_ms: parse_integer_env.("MAVE_GPU_ENCODING_BOOSTER_RETRY_JITTER_MS", 500)

  config :mave_core, :media_h264_ladder_encoder,
    preset: parse_string_env.("MAVE_H264_LADDER_PRESET", "veryfast"),
    tune: parse_string_env.("MAVE_H264_LADDER_TUNE", "none")

  # The secret key base is used to sign/encrypt cookies and other secrets.
  # A default value is used in config/dev.exs and config/test.exs but you
  # want to use a different value for prod and you most likely don't want
  # to check this value into version control, so we use an environment
  # variable instead.
  secret_key_base =
    System.get_env("SECRET_KEY_BASE") ||
      raise """
      environment variable SECRET_KEY_BASE is missing.
      You can generate one by calling: mix phx.gen.secret
      """

  host = System.get_env("PHX_HOST") || (external_uri && external_uri.host) || "example.com"

  url_scheme =
    System.get_env("PHX_URL_SCHEME") || (external_uri && external_uri.scheme) || "https"

  url_port =
    parse_integer_env.(
      "PHX_URL_PORT",
      (external_uri && external_uri.port) || if(url_scheme == "https", do: 443, else: 80)
    )

  config :mave_core, :dns_cluster_query, System.get_env("DNS_CLUSTER_QUERY")

  config :mave_core, MaveCoreWeb.Endpoint,
    url: [host: host, port: url_port, scheme: url_scheme],
    http: [
      # Enable IPv6 and bind on all interfaces.
      # Set it to  {0, 0, 0, 0, 0, 0, 0, 1} for local network only access.
      # See the documentation on https://hexdocs.pm/bandit/Bandit.html#t:options/0
      # for details about using IPv6 vs IPv4 and loopback vs public addresses.
      ip: {0, 0, 0, 0, 0, 0, 0, 0}
    ],
    secret_key_base: secret_key_base

  # ## SSL Support
  #
  # To get SSL working, you will need to add the `https` key
  # to your endpoint configuration:
  #
  #     config :mave_core, MaveCoreWeb.Endpoint,
  #       https: [
  #         ...,
  #         port: 443,
  #         cipher_suite: :strong,
  #         keyfile: System.get_env("SOME_APP_SSL_KEY_PATH"),
  #         certfile: System.get_env("SOME_APP_SSL_CERT_PATH")
  #       ]
  #
  # The `cipher_suite` is set to `:strong` to support only the
  # latest and more secure SSL ciphers. This means old browsers
  # and clients may not be supported. You can set it to
  # `:compatible` for wider support.
  #
  # `:keyfile` and `:certfile` expect an absolute path to the key
  # and cert in disk or a relative path inside priv, for example
  # "priv/ssl/server.key". For all supported SSL configuration
  # options, see https://hexdocs.pm/plug/Plug.SSL.html#configure/1
  #
  # We also recommend setting `force_ssl` in your config/prod.exs,
  # ensuring no data is ever sent via http, always redirecting to https:
  #
  #     config :mave_core, MaveCoreWeb.Endpoint,
  #       force_ssl: [hsts: true]
  #
  # Check `Plug.SSL` for all available options in `force_ssl`.

  case parse_string_env.("MAVE_MAILER_ADAPTER", "none") |> String.downcase() do
    "none" ->
      config :mave_core, MaveCore.Mailer, adapter: nil

    "smtp" ->
      smtp_relay =
        parse_optional_string_env.("SMTP_RELAY") ||
          raise "SMTP_RELAY is required when MAVE_MAILER_ADAPTER=smtp"

      smtp_username = parse_optional_string_env.("SMTP_USERNAME")
      smtp_password = parse_optional_string_env.("SMTP_PASSWORD")

      if is_nil(smtp_username) != is_nil(smtp_password) do
        raise "SMTP_USERNAME and SMTP_PASSWORD must either both be set or both be omitted"
      end

      smtp_tls =
        case parse_string_env.("SMTP_TLS", "always") |> String.downcase() do
          "always" -> :always
          "if_available" -> :if_available
          "never" -> :never
          value -> raise "SMTP_TLS must be always, if_available, or never; got: #{inspect(value)}"
        end

      smtp_config = [
        adapter: Swoosh.Adapters.SMTP,
        relay: smtp_relay,
        port: parse_integer_env.("SMTP_PORT", 587),
        auth: if(smtp_username, do: :always, else: :never),
        ssl: parse_boolean_env.("SMTP_SSL", false),
        tls: smtp_tls,
        retries: 2,
        no_mx_lookups: true
      ]

      smtp_config =
        if smtp_username do
          Keyword.merge(smtp_config, username: smtp_username, password: smtp_password)
        else
          smtp_config
        end

      config :mave_core, MaveCore.Mailer, smtp_config

    "scaleway" ->
      config :mave_core, MaveCore.Mailer,
        adapter: MaveCore.Mailer.ScalewayAdapter,
        project_id: System.get_env("SCW_TRANSACTIONAL_EMAIL_PROJECT_ID"),
        secret_key: System.get_env("SCW_TRANSACTIONAL_EMAIL_SECRET_KEY"),
        region: System.get_env("SCW_REGION") || "fr-par"

    value ->
      raise "MAVE_MAILER_ADAPTER must be none, smtp, or scaleway; got: #{inspect(value)}"
  end

  # Configure S3/Object Storage
  config :mave_core, :s3,
    access_key_id: System.get_env("S3_ACCESS_KEY"),
    secret_access_key: System.get_env("S3_SECRET_KEY"),
    endpoint: System.get_env("S3_ENDPOINT"),
    region: System.get_env("S3_REGION")

  config :mave_core, :bucket_prefix, System.get_env("BUCKET_PREFIX") || "space-"

  clickhouse_url =
    System.get_env("CLICKHOUSE_URL") ||
      raise """
      environment variable CLICKHOUSE_URL is missing.
      Example: https://your-clickhouse-host:8443
      """

  clickhouse_user = System.get_env("CLICKHOUSE_USER") || "mave_core"

  clickhouse_password =
    System.get_env("CLICKHOUSE_PASSWORD") ||
      raise """
      environment variable CLICKHOUSE_PASSWORD is missing.
      """

  clickhouse_database = System.get_env("CLICKHOUSE_DATABASE") || "mave_metrics"

  uri = URI.parse(clickhouse_url)

  config :mave_core, MaveCore.ClickHouseRepo,
    scheme: uri.scheme || "https",
    hostname: uri.host,
    port: uri.port || 8443,
    database: clickhouse_database,
    username: clickhouse_user,
    password: clickhouse_password,
    pool_size: String.to_integer(System.get_env("CLICKHOUSE_POOL_SIZE") || "10")

  config :ua_inspector,
    database_path:
      System.get_env("UA_INSPECTOR_DATABASE_PATH") ||
        Application.app_dir(:mave_core, "priv/ua_inspector")
end
