#!/usr/bin/env bash
# Build the sandbox image for a pull-request checkout.
#
#   prepare.sh <pull-request-checkout> [image-archive.tar.zst]
#
# Fetching and compiling dependencies executes pull-request code with network
# access, so run this only where no secrets exist. The toolchain and this
# directory come from the trusted checkout that contains this script.
set -euo pipefail

if [[ $# -lt 1 || ! -d "$1" ]]; then
  echo "usage: $0 <pull-request-checkout> [image-archive.tar.zst]" >&2
  exit 2
fi

here=$(cd "$(dirname "$0")" && pwd)
trusted=$(cd "$here/../.." && pwd)
checkout=$(cd "$1" && pwd)
archive=${2:-}
image=${AI_SANDBOX_IMAGE:-mave-ai-sandbox-pr}

# The base branch defines the toolchain, so a pull request cannot swap it.
docker build --target development --tag mave-ai-sandbox-toolchain "$trusted"

# -f selects the trusted Dockerfile and its Dockerfile.dockerignore; only the
# build context is untrusted.
docker build --file "$here/Dockerfile" --tag "$image" "$checkout"

if [[ -n "$archive" ]]; then
  docker save "$image" | zstd --quiet -T0 -3 -o "$archive"
  ls -lh "$archive"
fi
