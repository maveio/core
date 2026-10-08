#!/bin/sh
set -eu
source_dir=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
test_dir=$(mktemp -d)
trap 'rm -rf "$test_dir"' EXIT HUP INT TERM
mkdir "$test_dir/job" "$test_dir/other"
printf private > "$test_dir/other/secret"
cc -O2 -Wall -Wextra -Werror "$source_dir/broker_probe.c" -o "$test_dir/ffmpeg"
AWS_SECRET_ACCESS_KEY=test-only-parent-secret mave-media-broker \
  --scratch "$test_dir/job" -- "$test_dir/ffmpeg" \
  -headers 'Authorization: Bearer test-only-secret' \
  'https://storage.invalid/source?signature=test-only-secret' "$test_dir/other/secret"
python3 "$source_dir/stream_test.py"
