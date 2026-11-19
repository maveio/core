#!/usr/bin/env bash
# Rehearses the emergency delivery switch on one machine.
#
# Two independent storage providers, their edges, an authoritative DNS zone and
# a caching resolver run in Docker. Core syncs and checks the standby with the
# same commands an operator uses, then the primary is stopped and one DNS
# record moves delivery to the standby while a viewer keeps requesting media.
#
# Requires Docker Compose, FFmpeg and the Elixir toolchain from CONTRIBUTING.md.
# See docs/emergency_delivery_failover.md.
set -euo pipefail

here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
root="$(cd "$here/../../.." && pwd)"

export MAVE_DRILL_STATE="${MAVE_DRILL_STATE:-/tmp/mave-delivery-drill}"
export MAVE_DRILL_NET="${MAVE_DRILL_NET:-10.77.0}"
export MAVE_DRILL_POSTGRES_PORT="${MAVE_DRILL_POSTGRES_PORT:-55432}"
export MAVE_DRILL_PRIMARY_PORT="${MAVE_DRILL_PRIMARY_PORT:-19010}"
export MAVE_DRILL_STANDBY_PORT="${MAVE_DRILL_STANDBY_PORT:-19020}"
export MAVE_DRILL_EDGE_PORT="${MAVE_DRILL_EDGE_PORT:-19021}"
ttl="${MAVE_DRILL_TTL:-5}"
reaction="${MAVE_DRILL_REACTION_SECONDS:-5}"

primary_ip="$MAVE_DRILL_NET.11"
standby_ip="$MAVE_DRILL_NET.21"

# Core runs on the host against the drill's own database and storage.
export MIX_ENV=dev
export POSTGRES_HOST=localhost POSTGRES_PORT="$MAVE_DRILL_POSTGRES_PORT"
export S3_ENDPOINT="http://localhost:$MAVE_DRILL_PRIMARY_PORT"
export AWS_ACCESS_KEY_ID=drill-primary AWS_SECRET_ACCESS_KEY=drill-primary-secret
export AWS_REGION=us-east-1
export MAVE_PUBLIC_CDN_SCHEME=http MAVE_PUBLIC_CDN_HOST=cdn.drill.test
export MAVE_PUBLIC_CDN_MODE=subdomain
export MAVE_DELIVERY_STANDBY_S3_ENDPOINT="http://localhost:$MAVE_DRILL_STANDBY_PORT"
export MAVE_DELIVERY_STANDBY_S3_ACCESS_KEY=drill-standby
export MAVE_DELIVERY_STANDBY_S3_SECRET_KEY=drill-standby-secret
export MAVE_DELIVERY_STANDBY_EDGE_URL="http://127.0.0.1:$MAVE_DRILL_EDGE_PORT"

compose() { docker compose --progress quiet -f "$here/compose.yml" "$@"; }
core() { (cd "$root" && mix "$@"); }
step() { printf '\n\033[1m== %s\033[0m\n' "$*"; }
now() { date +%s.%N; }
elapsed() { awk -v a="$1" -v b="$2" 'BEGIN { printf "%.1f", b - a }'; }

write_zone() {
  mkdir -p "$MAVE_DRILL_STATE/zones"
  sed -e "s/__TTL__/$ttl/g" -e "s/__SERIAL__/$(date +%s)/" \
    -e "s/__AUTHORITY__/$MAVE_DRILL_NET.2/" -e "s/__PLAYER__/$MAVE_DRILL_NET.30/" \
    -e "s/__DELIVERY__/$1/" "$here/zone.template" >"$MAVE_DRILL_STATE/zones/drill.test.zone.new"
  mv "$MAVE_DRILL_STATE/zones/drill.test.zone.new" "$MAVE_DRILL_STATE/zones/drill.test.zone"
}

load_seed() {
  # shellcheck disable=SC1091
  . "$MAVE_DRILL_STATE/seed.env"
  media_host="space-$DRILL_SPACE.cdn.drill.test"
  export MAVE_DRILL_VIEWER_URL="http://$media_host/$DRILL_PUBLIC_EMBED/manifest.json"
}

wait_for_port() {
  for _ in $(seq 1 120); do
    if (exec 3<>"/dev/tcp/127.0.0.1/$1") 2>/dev/null; then return 0; fi
    sleep 0.5
  done
  echo "Port $1 did not open" >&2
  return 1
}

last_viewer_line() { compose logs --no-log-prefix --tail 1 viewer 2>/dev/null | tail -n 1; }

wait_for_viewer() {
  for _ in $(seq 1 600); do
    if last_viewer_line | grep -q "$1"; then return 0; fi
    sleep 0.2
  done
  echo "The viewer never reported: $1" >&2
  return 1
}

# Requests a path under the public hostname the way a viewer resolves it.
viewer_status() {
  compose run --rm --no-deps --entrypoint /bin/sh viewer -c \
    "wget -q -S -T 3 -O /dev/null 'http://$media_host/$1' 2>&1" 2>/dev/null |
    sed -n 's/.*HTTP\/[0-9.]* \([0-9][0-9][0-9]\).*/\1/p' | tail -n 1
}

up() {
  step "Start the primary, the standby and their DNS"
  write_zone "$primary_ip"
  compose up -d --wait postgres primary-storage primary-cdn standby-storage standby-edge dns resolver player
  until compose exec -T postgres pg_isready -q -U postgres; do sleep 0.5; done
  wait_for_port "$MAVE_DRILL_PRIMARY_PORT"
  wait_for_port "$MAVE_DRILL_STANDBY_PORT"

  step "Seed a space with a public and a private video on the primary"
  core ecto.migrate -r MaveCore.Repo --quiet
  core run --no-start "$here/seed.exs"
  load_seed
  compose --profile viewer up -d viewer
  echo "Public media: $MAVE_DRILL_VIEWER_URL"
  echo "Player page:  http://player.drill.test/?space=$DRILL_SPACE&embed=$DRILL_PUBLIC_EMBED"
}

sync() {
  step "Copy public media to the standby"
  core mave.delivery_standby sync "$@"
}

check() {
  step "Check whether delivery could be switched"
  core mave.delivery_standby check "$@"
}

outage() {
  step "Outage: stop the primary CDN and its storage"
  compose stop -t 1 primary-cdn primary-storage
}

switch() {
  step "Switch: point delivery.drill.test at the standby ($standby_ip)"
  write_zone "$standby_ip"
}

restore() {
  step "Restore: start the primary and point delivery.drill.test back ($primary_ip)"
  compose start primary-storage primary-cdn
  write_zone "$primary_ip"
}

watch() { compose logs --no-log-prefix --follow --tail 5 viewer; }

run() {
  up
  sync
  check
  load_seed

  step "A viewer requests media every second"
  wait_for_viewer "served-by=primary"
  compose logs --no-log-prefix --tail 3 viewer

  outage
  failed_at="$(now)"
  wait_for_viewer "http=ERR"
  echo "Viewers now fail: $(last_viewer_line)"

  echo "Operator reaction time: ${reaction}s"
  sleep "$reaction"

  switch
  switched_at="$(now)"
  wait_for_viewer "served-by=standby"
  recovered_at="$(now)"
  compose logs --no-log-prefix --tail 4 viewer

  step "Access rules on the standby"
  echo "Public manifest:  HTTP $(viewer_status "$DRILL_PUBLIC_EMBED/manifest.json")"
  echo "Public segment:   HTTP $(viewer_status "$DRILL_PUBLIC_EMBED/h264_360p/segment-000.ts")"
  echo "Private manifest: HTTP $(viewer_status "$DRILL_PRIVATE_EMBED/manifest.json")"

  step "Result"
  echo "DNS record TTL:               ${ttl}s"
  echo "Outage until the switch:      $(elapsed "$failed_at" "$switched_at")s"
  echo "Switch until viewers recover: $(elapsed "$switched_at" "$recovered_at")s"
  echo "Total interruption:           $(elapsed "$failed_at" "$recovered_at")s"
  echo
  echo "Browsers keep a resolved address for about a minute, so a player that was"
  echo "open during the outage follows later than this viewer."
  echo "The stack keeps running: 'drill.sh restore' switches back, 'drill.sh down' removes it."
}

down() {
  compose --profile viewer down --volumes --remove-orphans
  rm -rf "$MAVE_DRILL_STATE"
}

case "${1:-}" in
  up | sync | check | outage | switch | restore | watch | run | down)
    command="$1"
    shift
    if [ "$command" != up ] && [ "$command" != run ] && [ "$command" != down ]; then load_seed; fi
    "$command" "$@"
    ;;
  *)
    echo "Usage: $0 run | up | sync | check | watch | outage | switch | restore | down" >&2
    exit 64
    ;;
esac
