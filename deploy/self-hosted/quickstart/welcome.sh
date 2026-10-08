#!/bin/sh
set -eu

origin=${MAVE_BASE_URL:-http://localhost:4000}
origin=${origin%/}
host=${origin#*://}
response=$(mktemp)
trap 'rm -f "$response"' EXIT

# Wait for the setup route and detect whether the installation still needs an owner.
attempt=0
until wget -q -T 5 --header="Host: $host" -O "$response" http://app:4000/setup; do
  attempt=$((attempt + 1))
  if [ "$attempt" -ge 30 ]; then
    printf '%s\n' 'Mave is still starting. Check docker compose logs app, then try again.' >&2
    exit 1
  fi
  sleep 2
done

printf '\n%s\n' '  ┌──────────────────────────────────────────┐'
printf '%s\n' '  │  Mave is ready. Start publishing videos. │'
printf '%s\n\n' '  └──────────────────────────────────────────┘'
if grep -q 'id="installation-setup"' "$response"; then
  code=$(cat "${MAVE_SETUP_DIR:-/setup}/code")
  printf '  1. Open this setup link:\n\n     %s/setup#code=%s\n\n' "$origin" "$code"
  printf '%s\n' '  2. Enter your email to create your workspace.'
  printf '%s\n\n' '  3. Upload your first video.'
  printf '%s\n' '  The link fills in your one-time code. It stops working after setup.'
  printf '  Manual setup code: %s\n\n' "$code"
else
  printf '  Open your workspace: %s\n\n' "$origin"
fi
if [ "${MAVE_DEVELOPMENT:-false}" = true ]; then
  printf '  Local email inbox: %s/dev/mailbox\n' "$origin"
  printf '%s\n' '  No email service needed. Sign-in emails appear in this inbox.'
fi
printf '\n%s\n\n' '  Ctrl+C stops Mave. Your workspace and videos are saved.'
