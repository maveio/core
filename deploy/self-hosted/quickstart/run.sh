#!/bin/sh
set -eu
. /setup/environment.sh

export DATABASE_URL="ecto://mave_core:${POSTGRES_PASSWORD}@postgres/mave_core"
export MINIO_ROOT_USER="$S3_ACCESS_KEY" MINIO_ROOT_PASSWORD="$S3_SECRET_KEY"
export AWS_ACCESS_KEY_ID="$S3_ACCESS_KEY" AWS_SECRET_ACCESS_KEY="$S3_SECRET_KEY"

case "$1" in
  upload)
    shift
    exec /usr/local/share/docker-entrypoint.sh "$@" "-hooks-http=http://app:4000/internal/upload-hooks/tusd?secret=${MAVE_UPLOAD_HOOK_SECRET}"
    ;;
  *) exec "$@" ;;
esac
