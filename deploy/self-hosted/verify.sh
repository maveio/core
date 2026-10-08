#!/bin/sh

set -eu

script_dir=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
compose_file="$script_dir/compose.yml"
env_file="$script_dir/.env"

if [ ! -f "$env_file" ]; then
  printf 'Missing %s; run ./install.sh first.\n' "$env_file" >&2
  exit 1
fi

compose() {
  docker compose --env-file "$env_file" -f "$compose_file" "$@"
}

base_url=$(sed -n 's/^MAVE_BASE_URL=//p' "$env_file" | tail -n 1)

compose config --quiet
compose exec -T app /app/bin/ready

if command -v curl >/dev/null 2>&1; then
  response=$(curl -fsS "$base_url/health")
  [ "$response" = "UP" ] || {
    printf 'Unexpected health response: %s\n' "$response" >&2
    exit 1
  }
fi

compose ps
printf '\nSelf-hosted Mave is ready at %s\n' "$base_url"
