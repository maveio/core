#!/bin/sh
set -eu

# Generate configuration silently; the welcome service prints the setup link when ready.
# Database credentials and application secrets must remain in the volume.
setup_dir=${MAVE_SETUP_DIR:-/setup}
mkdir -p "$setup_dir"
umask 077

random_hex() {
  od -An -N "$1" -tx1 /dev/urandom | tr -d ' \n'
}

if [ ! -f "$setup_dir/environment.sh" ]; then
  temporary="$setup_dir/environment.tmp"
  : > "$temporary"
  for key in POSTGRES_PASSWORD CLICKHOUSE_PASSWORD S3_ACCESS_KEY S3_SECRET_KEY SECRET_KEY_BASE MAVE_CORE_INTERNAL_SECRET MAVE_UPLOAD_HOOK_SECRET RELEASE_COOKIE; do
    value=$(random_hex 64)
    printf 'export %s=${%s:=%s}\n' "$key" "$key" "$value" >> "$temporary"
  done
  chmod 444 "$temporary"
  mv "$temporary" "$setup_dir/environment.sh"
fi

if [ ! -f "$setup_dir/code" ]; then
  random_hex 24 > "$setup_dir/code.tmp"
  printf '\n' >> "$setup_dir/code.tmp"
  chmod 444 "$setup_dir/code.tmp"
  mv "$setup_dir/code.tmp" "$setup_dir/code"
fi
printf '%s\n' 'Configuration ready. Starting Mave…'
