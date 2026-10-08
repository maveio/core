#!/bin/sh

set -eu
umask 077

script_dir=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
core_dir=$(CDPATH= cd -- "$script_dir/../.." && pwd)
image=""

usage() {
  printf '%s\n' \
    'Usage: ./deploy/self-hosted/smoke.sh [--image LOCAL_IMAGE]' \
    '' \
    'Builds Core, then tests a fresh, isolated self-hosted installation.' \
    'Use --image to test an already-built local image without rebuilding.' \
    'Requires Docker Compose v2 with !reset support, openssl and Git.' \
    'No host ports, existing .env, development data or SaaS services are used.'
}

while [ "$#" -gt 0 ]; do
  case "$1" in
    --image) image=${2:?missing value for --image}; shift 2 ;;
    --help|-h) usage; exit 0 ;;
    *) printf 'Unknown option: %s\n' "$1" >&2; usage >&2; exit 2 ;;
  esac
done

for command in docker openssl git; do
  command -v "$command" >/dev/null 2>&1 || {
    printf 'Required command not found: %s\n' "$command" >&2
    exit 1
  }
done
# Keep every command on the same selected daemon while removing application env.
# Explicit contexts are portable between Docker Desktop, OrbStack and Linux.
[ -z "${DOCKER_HOST:-}" ] || {
  printf 'Select a Docker context instead of setting DOCKER_HOST for this test.\n' >&2
  exit 1
}
docker_context=$(docker context show)
docker_cli() {
  env -i PATH="$PATH" HOME="$HOME" DOCKER_CONFIG="${DOCKER_CONFIG:-$HOME/.docker}" \
    docker --context "$docker_context" "$@"
}
docker_cli compose version >/dev/null
docker_cli info >/dev/null
smoke_cpus=$(docker_cli info --format '{{.NCPU}}')
[ "$smoke_cpus" -le 4 ] || smoke_cpus=4

run_id="mave-core-smoke-$(openssl rand -hex 6)"
smoke_dir=$(mktemp -d "${TMPDIR:-/tmp}/mave-core-smoke.XXXXXXXX")
network_created=false
stack_started=false
cp "$script_dir/compose.yml" "$script_dir/compose.smoke.yml" "$script_dir/Caddyfile" "$smoke_dir/"
cp -R "$script_dir/../minio" "$smoke_dir/minio"

# Explicit files/project override any COMPOSE_* settings in the caller's shell.
# The subshell also excludes inherited application credentials and feature flags.
compose() (
  cd "$smoke_dir"
  docker_cli compose -p "$run_id" --env-file "$smoke_dir/.env" \
    -f "$smoke_dir/compose.yml" -f "$smoke_dir/compose.smoke.yml" "$@"
)

cleanup() {
  result=$?
  trap - EXIT HUP INT TERM
  if [ "$stack_started" = true ]; then
    compose logs --no-color >"$smoke_dir/services.log" 2>&1 || true
    if ! compose down --volumes --remove-orphans >"$smoke_dir/cleanup.log" 2>&1; then
      printf 'Could not remove test stack %s; see %s/cleanup.log\n' "$run_id" "$smoke_dir" >&2
      result=1
    fi
  fi
  if [ "$network_created" = true ]; then
    if ! docker_cli network rm "$run_id" >>"$smoke_dir/cleanup.log" 2>&1; then
      printf 'Could not remove test network %s.\n' "$run_id" >&2
      result=1
    fi
  fi
  printf 'Private run logs: %s\n' "$smoke_dir"
  [ "$result" -eq 0 ] || printf 'Smoke test FAILED. Existing installations were not changed.\n' >&2
  exit "$result"
}
trap cleanup EXIT
trap 'exit 130' INT
trap 'exit 143' HUP TERM

revision=$(git -C "$core_dir" rev-parse HEAD 2>/dev/null || printf '%s' source-archive)
if [ "$revision" != source-archive ]; then
  if [ -n "$(git -C "$core_dir" status --porcelain)" ]; then
    revision="${revision}-dirty"
  fi
fi
printf 'Core checkout: %s\n' "$revision"
if [ -z "$image" ]; then
  image="mave-core:$run_id"
  printf 'Building the release image (first run can take several minutes)...\n'
  docker_cli build --target final --build-arg "VCS_REF=$revision" \
    --tag "$image" "$core_dir" >"$smoke_dir/build.log" 2>&1
fi
image_id=$(docker_cli image inspect --format '{{.Id}}' "$image")
printf 'Testing image: %s\n' "$image_id"
docker_cli image inspect --format '{{.Id}} {{json .Config.Labels}}' "$image" >"$smoke_dir/image.txt"

# Let Docker choose an unused subnet. Only this newly-created network is removed.
docker_cli network create --label "io.mave.smoke=$run_id" "$run_id" >"$smoke_dir/network.txt"
network_created=true
gateway=$(docker_cli network inspect --format '{{(index .IPAM.Config 0).Gateway}}' "$run_id")
subnet=$(docker_cli network inspect --format '{{(index .IPAM.Config 0).Subnet}}' "$run_id")
# Static container addresses require an explicitly configured subnet on Docker Engine.
docker_cli network rm "$run_id" >>"$smoke_dir/network.txt"
network_created=false
docker_cli network create --label "io.mave.smoke=$run_id" --subnet "$subnet" \
  --gateway "$gateway" "$run_id" >>"$smoke_dir/network.txt"
network_created=true
# Leave room for the automatically-assigned service addresses before Caddy starts.
caddy_ip=$(printf '%s\n' "$gateway" | awk -F. 'NF == 4 && $4 + 10 < 255 {print $1 "." $2 "." $3 "." $4 + 10}')
[ -n "$caddy_ip" ] || { printf 'An IPv4 Docker network is required.\n' >&2; exit 1; }

# These are disposable test credentials, never copied from an installation.
{
  printf 'MAVE_SMOKE_RUN_ID=%s\n' "$run_id"
  printf 'MAVE_CORE_IMAGE=%s\n' "$image_id"
  printf 'MAVE_CORE_CPU_LIMIT=%s\n' "$smoke_cpus"
  printf 'MAVE_BASE_URL=http://localhost\nMAVE_CADDY_ADDRESS=:80\n'
  printf 'MAVE_CADDY_INTERNAL_IP=%s\n' "$caddy_ip"
  for key in POSTGRES_PASSWORD CLICKHOUSE_PASSWORD S3_ACCESS_KEY S3_SECRET_KEY \
    MAVE_CORE_INTERNAL_SECRET MAVE_UPLOAD_HOOK_SECRET RELEASE_COOKIE; do
    printf '%s=%s\n' "$key" "$(openssl rand -hex 32)"
  done
  printf 'SECRET_KEY_BASE=%s\n' "$(openssl rand -hex 64)"
  printf 'MAVE_MAILER_ADAPTER=none\n'
} >"$smoke_dir/.env"

compose config --quiet
# Refuse even an extremely unlikely project-name collision before touching data.
[ -z "$(compose ps --all --quiet)" ] || {
  printf 'Refusing to reuse existing project %s.\n' "$run_id" >&2
  exit 1
}
printf 'Starting isolated services (no host ports)...\n'
stack_started=true
compose up -d --wait --wait-timeout 180 app upload caddy >"$smoke_dir/start.log" 2>&1
compose exec -T app /app/bin/ready >"$smoke_dir/ready.log" 2>&1
# Docker cp cannot write through a read-only container root into tmpfs.
compose exec -T app sh -c 'cat > /tmp/mave-core-smoke.exs' < "$script_dir/smoke.exs"

printf 'Checking bootstrap, API, upload, processing, HLS and analytics...\n'
if compose exec -T app /app/bin/mave_core rpc 'Code.eval_file("/tmp/mave-core-smoke.exs")' \
  >"$smoke_dir/journey.log" 2>&1; then
  sed -n '/^PASS:/p' "$smoke_dir/journey.log"
else
  printf 'Product journey failed; see %s/journey.log\n' "$smoke_dir" >&2
  exit 1
fi
printf 'Smoke test PASSED. Removing only this run\047s containers, volumes and network.\n'
