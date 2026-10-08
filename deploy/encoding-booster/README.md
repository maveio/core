# Mave Core encoding booster

This directory contains the implementation and container image source for
Core's optional CPU and GPU encoding boosters. Keeping the request handler beside the
Core client lets their streaming contract and tests evolve together.

This integration is optional: the single-host installation processes media
locally without a booster. When enabled, a dedicated Oban queue coordinates
requests and sends independent renditions to the remote CPU service:

```text
object storage -> CPU Serverless FFmpeg -> object storage
                         ^
                         |
             Core worker (control metadata only)
```

GPU and FLAME routes remain optional deployment fallbacks, but neither is
required for the normal CPU-booster path.

The CPU image contains a static Go HTTP wrapper and a checksummed FFmpeg 9.0.2
source build with `libmp3lame`, `libwebp`, `libx264`, `libx265`, and
`libsvtav1`, plus `libdav1d` for software AV1 decoding. The GPU image
uses Ubuntu FFmpeg with H.264/HEVC/AV1 NVENC. Both stream the external HTTPS
source through FFmpeg. The normal H.264 CPU contract receives short-lived,
object-scoped multipart URLs from Core and uploads FFmpeg's stdout directly to
object storage with bounded memory. It returns newline-delimited progress and
completion metadata; the Core worker never receives or stages the media bytes.
Long renditions use durable, deterministic chunk objects and the `/concat`
endpoint downloads complete chunks to private booster scratch before joining
them into a remote multipart destination. Downloads use the trusted source
client with bounded retries and a combined 16 GiB source limit per request.
Each chunk must contain valid video packets, and the final packet count must
equal the sum of the input counts before the multipart upload can complete.
Preparation emits heartbeats and all scratch is removed on every exit path.
Provision at least that source allowance per concurrent concat request, plus
space for other work. HLS packaging uses streaming output: FFmpeg finalizes
each segment through an atomic temporary-file rename, then the booster exchanges
a short-lived scoped token for that segment's signed PUT destination. Finalized
segments are uploaded to object storage and removed from booster scratch while
FFmpeg continues; the init file and playlist are published last. This keeps
scratch bounded to in-flight segment files instead of retaining the complete HLS
package. The booster returns metadata only. Audio extraction,
poster/thumbnail/placeholder frame extraction, and audio HLS packaging use the
same direct-storage contract, so manifest-critical media never traverses or
lands on the coordinating application worker. The legacy ZIP
response remains available for rolling compatibility, but the normal Core flow
does not download or extract that bundle.

Seek-preview segments and direct-storage storyboards first download the SD H.264
source to a private temporary directory on the booster, then extract their images
from that completed local file. This avoids remote partial reads and repeated
HTTP range reads while seeking. The download
uses the trusted source client's address checks and redirect policy, makes at
most three attempts for transport failures, incomplete responses, and temporary
HTTP failures, and reports the source HTTP status without exposing signed URLs.
Each attempt has a ten-minute deadline within the request's overall timeout.
The source is limited to 8 GiB (including responses without Content-Length),
progress heartbeats continue during preparation, and scratch is removed on
success, failure, or cancellation. Provision enough booster scratch for that
bound per concurrent request. All requested thumbnails must still complete;
partial sets are not reported as successful. Outputs continue to upload directly
to object storage, and the application worker does not stage any media.

Video encoding and concatenation reject FFmpeg input errors and empty output
instead of completing a partial rendition. HLS packaging also fails on those
errors, but first attempts to resume interrupted HTTP reads and retries temporary
408/429/5xx responses, up to three retries with at most 15 seconds of retry delay.
Normal EOF is not retried. HLS sources remain streamed
so large renditions do not require holding the full source on scratch disk.

The previous Alpine runtime supplied FFmpeg 6.1.2. FFmpeg 9.0.2 is built from the
official release tarball with its SHA-256 pinned in the Dockerfile, so changing
the version or source bytes is explicit and reviewable. The image build verifies
the release version and all required external codecs, including actual WebP
frame encoding and AV1-to-JPEG/H.264 decoding and transcoding in the final
runtime image.

Normal video uploads asynchronously hit the CPU booster's `/warmup` endpoint
and the GPU booster's `/health` endpoint from the authorized tusd `pre-create`
hook. CPU warmup deliberately uses a route other than the configured platform
health check so its held requests count toward Scaleway autoscaling. The
non-blocking `post-receive` hook refreshes CPU capacity while bytes continue to
arrive. This overlaps serverless cold start with the user's upload without
delaying or rejecting the upload when warmup fails.

## Audio waveform peaks

`media.generate_audio_peaks` uses the CPU booster when enabled and shares the
background booster queue and admission limits. The `audio_peaks` operation reads
the already-transcoded audio when available, measures up to 512 amplitude buckets,
and returns at most 64 KiB of text metadata. Core validates the measurements and
publishes the existing `audio_peaks.json` and manifest waveform payload. No media
bytes are returned to the coordinating worker. Silence and opposite-phase stereo
retain the same behavior as the FLAME implementation.

This remains optional background work. A busy booster uses the normal retry path;
other errors fall back to FLAME when `fallback_enabled` is enabled. With boosters
disabled, the step runs on FLAME. Deploy the booster image with `audio_peaks`
support before the updated Core/SaaS release; an older booster rejects the new
operation and requires the configured FLAME fallback.

## Configure your deployment

Build the encoder image from this directory and deploy it on compute you
operate. The CPU client supports Scaleway IAM authentication; the GPU client
uses a bearer token. These are specific optional integrations, not a generic
serverless provisioning system.

You are responsible for endpoint access control, network reachability, capacity,
and secret management. Grant only the required invocation permission and
configure the applicable worker runtime values:

```text
MAVE_ENCODING_BOOSTER_ENABLED=true
MAVE_ENCODING_BOOSTER_ENDPOINT=https://encoding-booster.example.com
MAVE_ENCODING_BOOSTER_IAM_SECRET_KEY=<secret-management value>
MAVE_ENCODING_BOOSTER_FALLBACK_ENABLED=true
MAVE_ENCODING_BOOSTER_READINESS_CHECK_ENABLED=true
MAVE_ENCODING_BOOSTER_READINESS_TIMEOUT_MS=1500
MAVE_ENCODING_BOOSTER_WARMUP_HOLD_MS=15000
MAVE_ENCODING_BOOSTER_RETRY_BACKOFF_MS=250,500,1000
MAVE_ENCODING_BOOSTER_BUSY_RETRY_BACKOFF_MS=250,500,1000,2000,4000
MAVE_ENCODING_BOOSTER_RETRY_JITTER_MS=100
MAVE_GPU_ENCODING_BOOSTER_ENABLED=true
MAVE_GPU_ENCODING_BOOSTER_ENDPOINT=http://<private-vpc-ip>:8080
MAVE_GPU_ENCODING_BOOSTER_BEARER_TOKEN=<secret-management value>
MAVE_GPU_ENCODING_BOOSTER_FALLBACK_ENABLED=true
MAVE_GPU_ENCODING_BOOSTER_READINESS_CHECK_ENABLED=true
MAVE_GPU_ENCODING_BOOSTER_READINESS_TIMEOUT_MS=1000
MAVE_GPU_ENCODING_BOOSTER_RETRY_BACKOFF_MS=250,500
MAVE_GPU_ENCODING_BOOSTER_RETRY_JITTER_MS=100
```

The CPU booster container itself also needs the environment-specific callback:

```text
HLS_UPLOAD_CALLBACK_URL=https://api.example.com/internal/encoding-booster/hls-uploads
```

The callback accepts only a short-lived token signed by Core. It returns URLs
bound to the exact destination keys, content types, content lengths, and public
ACL policy; it never exposes storage credentials.

Scaleway owns horizontal scaling, but its concurrency threshold is not a strict
per-process admission limit. Configure the service with a threshold of one and
set `MAX_CONCURRENT_REQUESTS=1` so the encoder also rejects overlapping FFmpeg
work with a retryable `429`. Each process includes a random
`X-Mave-Booster-Instance` response header and logs the same identifier so
parallel flow outputs can be correlated with distinct serverless instances.

Core retries transient `429`, `500`, `502`, `503`, `504`, and transport failures using
the bounded backoff above before delegating to FLAME. Deterministic request or
FFmpeg failures are not retried.

Booster routing is latency-first. Before submitting an encode, Core can check
the executor's `/health` endpoint with a short, separately configured deadline.
A GPU pool that is still starting immediately delegates to the CPU Serverless
booster; unavailable CPU capacity immediately delegates to warm FLAME. Neither
cold start consumes the long encode request timeout. Keep the request retry
budgets short as a second guard against capacity races after a successful
readiness check.

The GPU service exposes authenticated `/drain` and `/resume` lifecycle endpoints.
Draining makes `/health` unavailable and rejects new encodes, allowing an
operator to take the instance out of service. Instance startup, shutdown, and
scaling automation are not included in this directory.

## Validate locally

Run the Go tests:

```sh
(cd deploy/encoding-booster/encoder && go test ./...)
```

Build the production architecture (the Docker build also runs the Go tests):

```sh
docker buildx build --platform linux/amd64 --load \
  --tag mave-core-encoding-booster:local \
  deploy/encoding-booster/encoder
```

Build the GPU image and verify all NVENC encoders are present:

```sh
docker buildx build --platform linux/amd64 --load \
  --file deploy/encoding-booster/encoder/Dockerfile.gpu \
  --tag mave-core-gpu-encoding-booster:local \
  deploy/encoding-booster/encoder
```

## Media processing security

Both encoder images require the shared Linux parser sandbox. The launcher clears
inherited credentials, restricts filesystem/process access and bounds resources.
A per-command broker preserves direct storage streaming and seeking while
keeping URLs/credentials outside FFmpeg and blocking its native network access.
See [media security](../../docs/media_security.md) for kernel/runtime requirements,
Kubernetes policy, resource limits and GPU validation.
