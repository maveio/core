#!/bin/sh
set -eu
sandbox_source=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
sandbox_test=$(mktemp -d)
trap 'rm -rf "$sandbox_test"' EXIT HUP INT TERM
cc -O2 -Wall -Wextra -Werror "$sandbox_source/media_sandbox.c" -lseccomp -o "$sandbox_test/launcher"
cc -O2 -Wall -Wextra -Werror "$sandbox_source/probe.c" -pthread -lseccomp -o "$sandbox_test/ffmpeg"
mkdir "$sandbox_test/job" "$sandbox_test/other-job" "$sandbox_test/root"
printf 'private marker\n' > "$sandbox_test/other-job/secret"
printf asset > "$sandbox_test/asset"
ln -s "$sandbox_test/other-job/secret" "$sandbox_test/job/escape"
SANDBOX_TEST_SECRET=private AWS_SECRET_ACCESS_KEY=private \
  "$sandbox_test/launcher" --root "$sandbox_test/root" --scratch "$sandbox_test/job" --read-only "$sandbox_test/asset" -- \
  "$sandbox_test/ffmpeg" "$sandbox_test/other-job/secret" "$sandbox_test/job" "$sandbox_test/asset"
test "$(cat "$sandbox_test/other-job/secret")" = 'private marker'
# An unsupported kernel must never fall back to executing the parser.
if MAVE_MEDIA_SANDBOX_BACKEND=landlock "$sandbox_test/ffmpeg" unsupported "$sandbox_test/launcher" -- /usr/bin/ffmpeg -version > "$sandbox_test/unsupported.log" 2>&1; then
  echo 'unexpected unconfined execution' >&2
  exit 1
fi
grep -q 'Landlock ABI 3 or newer is required' "$sandbox_test/unsupported.log"
# Exercise actual decoder/encoder threads, probing and HLS output.
media_ffmpeg=$(command -v ffmpeg)
media_ffprobe=$(command -v ffprobe)
"$sandbox_test/launcher" --root "$sandbox_test/root" --scratch "$sandbox_test/job" -- "$media_ffmpeg" -nostdin -v error \
  -f lavfi -i testsrc2=size=128x72:rate=25 -t 0.5 -c:v libx264 "$sandbox_test/job/source.mp4"
"$sandbox_test/launcher" --root "$sandbox_test/root" --scratch "$sandbox_test/job" -- "$media_ffprobe" -v error \
  -show_entries format=duration -of json "$sandbox_test/job/source.mp4"
"$sandbox_test/launcher" --root "$sandbox_test/root" --scratch "$sandbox_test/job" -- "$media_ffmpeg" -nostdin -v error \
  -i "$sandbox_test/job/source.mp4" -c copy -f hls "$sandbox_test/job/playlist.m3u8"
test -s "$sandbox_test/job/playlist.m3u8"
echo 'media sandbox tests passed'
