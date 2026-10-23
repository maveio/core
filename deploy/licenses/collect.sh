#!/bin/sh
# Build-time collection only; does not run or modify the application.
set -eu

project_dir=${1:?Usage: collect.sh PROJECT_DIR OUTPUT_DIR}
output_dir=${2:?Usage: collect.sh PROJECT_DIR OUTPUT_DIR}
case "$output_dir" in
  /*) ;;
  *) printf 'OUTPUT_DIR must be absolute\n' >&2; exit 1 ;;
esac
[ ! -e "$output_dir" ] || { printf 'OUTPUT_DIR must not exist\n' >&2; exit 1; }

cd "$project_dir"

# A dependency upgrade must not silently ship a different data licence.
data_version=$(sed -n 's/^  @remote_release "\([^"]*\)"$/\1/p' deps/ua_inspector/lib/ua_inspector/config.ex)
[ "$data_version" = "$(cat deploy/licenses/device-detector/VERSION)" ] || {
  printf 'Review the Device Detector data licence for this UAInspector version\n' >&2
  exit 1
}

mkdir -p "$output_dir/data" "$output_dir/manifests"
cp LICENSE THIRD_PARTY_NOTICES.md Dockerfile "$output_dir/"
cp mix.lock "$output_dir/manifests/"
cp assets/package-lock.json "$output_dir/manifests/npm-package-lock.json"
cp -R deploy/licenses/device-detector "$output_dir/data/"

# Keep original relative paths so identically named notices cannot overwrite
# each other. Include transitive dependencies, not just direct package names.
find deps assets/node_modules \
  -type d \( -name .git -o -name _build -o -name target \) -prune -o \
  -type f \( -iname 'license*' -o -iname 'licence*' -o -iname 'copying*' \
    -o -iname 'notice*' -o -iname 'copyright*' -o -name Cargo.lock \
    -o -name hex_metadata.config \) \
  -exec sh -eu -c '
    output=$1
    shift
    for source do
      mkdir -p "$output/$(dirname "$source")"
      cp "$source" "$output/$source"
    done
  ' sh "$output_dir" {} +
