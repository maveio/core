#!/usr/bin/env bash
# Start the sandbox and its services, then verify that it is isolated.
#
#   start.sh [image-archive.tar.zst]
#
# Exits non-zero, before any model is involved, when an isolation check fails.
set -euo pipefail

here=$(cd "$(dirname "$0")" && pwd)
trusted=$(cd "$here/../.." && pwd)
export AI_SANDBOX_IMAGE=${AI_SANDBOX_IMAGE:-mave-ai-sandbox-pr}
export AI_SANDBOX_MINIO_IMAGE=${AI_SANDBOX_MINIO_IMAGE:-mave-ai-sandbox-minio}

if [[ -n "${1:-}" ]]; then
  zstd --decompress --stdout "$1" | docker load
fi

if ! docker image inspect "$AI_SANDBOX_MINIO_IMAGE" >/dev/null 2>&1; then
  docker build --target server --tag "$AI_SANDBOX_MINIO_IMAGE" "$trusted/deploy/minio"
fi

docker compose --file "$here/compose.yml" up --detach --wait --wait-timeout 180

python3 "$trusted/.github/scripts/ai_sandbox.py" preflight
