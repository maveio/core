#!/bin/sh

set -eu

script_dir=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
compose_file="$script_dir/compose.yml"
env_file="$script_dir/.env"

base_url=""
owner_email=""
core_image=""
http_port="4000"
https_port="4443"
minio_console_port="9001"
http_port_set="false"
https_port_set="false"
minio_console_port_set="false"
non_interactive="false"

usage() {
  printf '%s\n' \
    "Usage: ./install.sh [options]" \
    "" \
    "  --base-url URL       Public origin (default: http://localhost:4000)" \
    "  --owner-email EMAIL  First owner; receives a one-time login link" \
    "  --image IMAGE        Core release image (default: ghcr.io/maveio/core:0.1.0)" \
    "  --http-port PORT     Host HTTP port (default: 4000)" \
    "  --https-port PORT    Host HTTPS port (default: 4443)" \
    "  --minio-console-port PORT" \
    "                         Loopback MinIO console port (default: 9001)" \
    "  --non-interactive    Fail instead of prompting" \
    "  --help               Show this help"
}

while [ "$#" -gt 0 ]; do
  case "$1" in
    --base-url)
      base_url=${2:?missing value for --base-url}
      shift 2
      ;;
    --owner-email)
      owner_email=${2:?missing value for --owner-email}
      shift 2
      ;;
    --image)
      core_image=${2:?missing value for --image}
      shift 2
      ;;
    --http-port)
      http_port=${2:?missing value for --http-port}
      http_port_set="true"
      shift 2
      ;;
    --https-port)
      https_port=${2:?missing value for --https-port}
      https_port_set="true"
      shift 2
      ;;
    --minio-console-port)
      minio_console_port=${2:?missing value for --minio-console-port}
      minio_console_port_set="true"
      shift 2
      ;;
    --non-interactive)
      non_interactive="true"
      shift
      ;;
    --help|-h)
      usage
      exit 0
      ;;
    *)
      printf 'Unknown option: %s\n\n' "$1" >&2
      usage >&2
      exit 2
      ;;
  esac
done

require_command() {
  if ! command -v "$1" >/dev/null 2>&1; then
    printf 'Required command not found: %s\n' "$1" >&2
    exit 1
  fi
}

env_value() {
  key=$1
  sed -n "s/^${key}=//p" "$env_file" | tail -n 1
}

valid_port() {
  case "$1" in
    ''|*[!0-9]*) return 1 ;;
    *) [ "$1" -ge 1 ] && [ "$1" -le 65535 ] ;;
  esac
}

ensure_port_available() {
  port=$1

  if command -v lsof >/dev/null 2>&1; then
    if lsof -nP -iTCP:"$port" -sTCP:LISTEN >/dev/null 2>&1; then
      printf 'Port %s is already in use. Choose another port.\n' "$port" >&2
      exit 1
    fi
  elif command -v ss >/dev/null 2>&1; then
    if ss -ltn | awk '{print $4}' | awk -F: -v port="$port" '$NF == port {found=1} END {exit !found}'; then
      printf 'Port %s is already in use. Choose another port.\n' "$port" >&2
      exit 1
    fi
  else
    printf 'Warning: neither lsof nor ss is available; skipping the port %s check.\n' "$port" >&2
  fi
}

require_command docker
require_command openssl
require_command sed

if ! docker compose version >/dev/null 2>&1; then
  printf 'Docker Compose v2 is required (the command must be "docker compose").\n' >&2
  exit 1
fi

if ! docker info >/dev/null 2>&1; then
  printf 'The Docker daemon is not available. Start Docker and rerun the installer.\n' >&2
  exit 1
fi

if [ ! -w "$script_dir" ]; then
  printf 'The installation directory is not writable: %s\n' "$script_dir" >&2
  exit 1
fi

if [ -f "$env_file" ]; then
  printf 'Reusing existing configuration: %s\n' "$env_file"
  configured_base_url=$(env_value MAVE_BASE_URL)
  configured_core_image=$(env_value MAVE_CORE_IMAGE)
  configured_http_port=$(env_value MAVE_HTTP_PORT)
  configured_https_port=$(env_value MAVE_HTTPS_PORT)
  configured_minio_console_port=$(env_value MAVE_MINIO_CONSOLE_PORT)
  [ -n "$configured_minio_console_port" ] || configured_minio_console_port="9001"

  if { [ -n "$base_url" ] && [ "$base_url" != "$configured_base_url" ]; } ||
     { [ -n "$core_image" ] && [ "$core_image" != "$configured_core_image" ]; } ||
     { [ "$http_port_set" = "true" ] && [ "$http_port" != "$configured_http_port" ]; } ||
     { [ "$https_port_set" = "true" ] && [ "$https_port" != "$configured_https_port" ]; } ||
     { [ "$minio_console_port_set" = "true" ] &&
       [ "$minio_console_port" != "$configured_minio_console_port" ]; }; then
    printf 'Existing configuration differs from the requested options. Edit %s explicitly before rerunning.\n' "$env_file" >&2
    exit 1
  fi

  base_url=$configured_base_url
  core_image=$configured_core_image
  http_port=$configured_http_port
  https_port=$configured_https_port
  minio_console_port=$configured_minio_console_port
else
  [ -n "$base_url" ] || base_url="http://localhost:${http_port}"
  [ -n "$core_image" ] || core_image="ghcr.io/maveio/core:0.1.0"
fi

base_url=${base_url%/}

case "$base_url" in
  http://*|https://*) ;;
  *)
    printf 'The base URL must start with http:// or https://.\n' >&2
    exit 1
    ;;
esac

authority=${base_url#*://}
case "$authority" in
  ''|*/*|*\?*|*\#*|*' '*)
    printf 'The base URL must be an origin without a path, query, fragment, or spaces.\n' >&2
    exit 1
    ;;
esac

base_host=$(printf '%s\n' "$base_url" | sed -E 's#^https?://(\[[^]]+\]|[^:/]+)(:[0-9]+)?$#\1#')
if [ "$base_host" = "$base_url" ] || [ -z "$base_host" ]; then
  printf 'Could not determine a hostname from the base URL.\n' >&2
  exit 1
fi

if ! valid_port "$http_port" || ! valid_port "$https_port" ||
   ! valid_port "$minio_console_port"; then
  printf 'HTTP, HTTPS, and MinIO console ports must be integers between 1 and 65535.\n' >&2
  exit 1
fi

if [ "$http_port" = "$https_port" ] ||
   [ "$http_port" = "$minio_console_port" ] ||
   [ "$https_port" = "$minio_console_port" ]; then
  printf 'HTTP, HTTPS, and MinIO console ports must be different.\n' >&2
  exit 1
fi

if [ "$non_interactive" != "true" ] && [ -z "$owner_email" ]; then
  printf 'First owner email: '
  IFS= read -r owner_email
fi

case "$owner_email" in
  *@*.*) ;;
  *)
    printf 'A valid --owner-email is required.\n' >&2
    exit 1
    ;;
esac

running_services=$(docker compose --env-file "$env_file" -f "$compose_file" ps --status running --services 2>/dev/null || true)
if [ -z "$running_services" ]; then
  ensure_port_available "$http_port"
  ensure_port_available "$https_port"
  ensure_port_available "$minio_console_port"
fi

if [ ! -f "$env_file" ]; then
  if [ "${base_url#https://}" != "$base_url" ]; then
    caddy_address=$base_host
  else
    caddy_address=":80"
  fi

  umask 077
  {
    printf 'MAVE_CORE_IMAGE=%s\n' "$core_image"
    printf 'MAVE_BASE_URL=%s\n' "$base_url"
    printf 'MAVE_CADDY_ADDRESS=%s\n' "$caddy_address"
    printf 'MAVE_HTTP_PORT=%s\n' "$http_port"
    printf 'MAVE_HTTPS_PORT=%s\n' "$https_port"
    printf 'MAVE_MINIO_CONSOLE_PORT=%s\n' "$minio_console_port"
    printf 'MAVE_DOCKER_SUBNET=%s\n' "${MAVE_DOCKER_SUBNET:-172.30.0.0/24}"
    # Keep the proxy away from Docker's first automatically assigned addresses.
    printf 'MAVE_CADDY_INTERNAL_IP=%s\n' "${MAVE_CADDY_INTERNAL_IP:-172.30.0.254}"
    printf 'POSTGRES_PASSWORD=%s\n' "$(openssl rand -hex 32)"
    printf 'CLICKHOUSE_PASSWORD=%s\n' "$(openssl rand -hex 32)"
    printf 'S3_ACCESS_KEY=%s\n' "$(openssl rand -hex 16)"
    printf 'S3_SECRET_KEY=%s\n' "$(openssl rand -hex 32)"
    printf 'SECRET_KEY_BASE=%s\n' "$(openssl rand -hex 64)"
    printf 'MAVE_CORE_INTERNAL_SECRET=%s\n' "$(openssl rand -hex 32)"
    printf 'MAVE_UPLOAD_HOOK_SECRET=%s\n' "$(openssl rand -hex 32)"
    printf 'RELEASE_COOKIE=%s\n' "$(openssl rand -hex 32)"
    printf 'MAVE_MEDIA_INPUT_MAX_BYTES=21474836480\n'
    printf 'MAVE_MAILER_ADAPTER=none\n'
    printf 'MAVE_EMAIL_FROM_NAME=Mave\n'
    printf 'MAVE_EMAIL_FROM_ADDRESS=noreply@localhost\n'
    printf 'SMTP_RELAY=\nSMTP_PORT=587\nSMTP_USERNAME=\nSMTP_PASSWORD=\nSMTP_TLS=always\nSMTP_SSL=false\n'
  } >"$env_file"

  printf 'Generated configuration and secrets: %s\n' "$env_file"
fi

# Core refuses to start without a per-installation distribution cookie. Add one
# to configurations generated before that requirement.
if [ -z "$(env_value RELEASE_COOKIE)" ]; then
  if [ -n "$(tail -c 1 "$env_file")" ]; then
    printf '\n' >>"$env_file"
  fi
  printf 'RELEASE_COOKIE=%s\n' "$(openssl rand -hex 32)" >>"$env_file"
  printf 'Added a distribution cookie to %s\n' "$env_file"
fi

compose() {
  docker compose --env-file "$env_file" -f "$compose_file" "$@"
}

compose config --quiet

compose pull postgres clickhouse upload caddy
compose build --pull minio storage-init

if ! docker image inspect "$core_image" >/dev/null 2>&1; then
  docker pull "$core_image"
fi

compose up -d app upload caddy

attempt=0
until compose exec -T app /app/bin/ready >/dev/null 2>&1; do
  attempt=$((attempt + 1))
  if [ "$attempt" -ge 90 ]; then
    printf 'Mave did not become ready within three minutes.\n' >&2
    compose ps >&2
    exit 1
  fi
  sleep 2
done

printf '\nMave is ready at %s\n\n' "$base_url"
compose run --rm -e MAVE_BOOTSTRAP_EMAIL="$owner_email" bootstrap

printf '\nKeep %s private; it contains all installation secrets.\n' "$env_file"
printf 'Run ./verify.sh at any time to recheck the stack.\n'
