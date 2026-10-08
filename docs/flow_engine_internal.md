# Flow Engine Internal Knobs

This document is for migration/debug workflows.
It is intentionally separate from the OSS-facing `flow_engine.md`.

## Step Mode Knobs

Most media steps support `*_mode`:

- `auto` (default): use FFmpeg for URL inputs; allow fallback/copy behavior when available
- `ffmpeg`: force FFmpeg execution path
- `copy`: bypass FFmpeg and copy source bytes

Current mode knobs:

- `media_transcode_video_mode`
- `media_transcode_h264_ladder_mode`
- `media_transcode_audio_mode`
- `media_extract_frame_mode`
- `media_generate_segments_mode`
- `media_generate_storyboard_mode`

## Step Strict Knobs

Most media steps support strict mode in two ways:

- step parameter: `"params": { "strict": true }` (recommended for flow definitions / visual builder)
- run input knobs: `*_strict` (useful for migration/debug overrides)

When both are present, the run-input `*_strict` value takes precedence for that run.

- `false` (default): step may return `unavailable`/`skipped`; run continues
- `true`: step errors fail the run

Current strict knobs:

- `media_transcode_video_strict`
- `media_transcode_h264_ladder_strict`
- `media_transcode_audio_strict`
- `media_extract_frame_strict`
- `media_generate_segments_strict`
- `media_generate_storyboard_strict`
- `media_package_hls_variant_strict`
- `media_package_hls_audio_strict`
- `media_build_hls_master_strict`
- `ai_transcribe_audio_strict`
- `cdn_purge_strict`
- `notify_webhook_strict` (or `event_notify_webhook_strict`)

## Other Runtime Overrides

- `media_probe`: deterministic metadata override for `media.inspect`
- `upload_ffmpeg_input_url`: direct storage URL emitted by the tusd upload hook
- `MAVE_FLOW_DIRECT_STORAGE_FFMPEG_INPUT=true`: lets FFmpeg/ffprobe stream
  storage-backed inputs instead of first copying them to runner scratch space.
  Direct-read access depends on the configured storage profile and bucket policy;
  it is not an instruction to make upload buckets public. Bucket-level browser
  CORS is best-effort and does not abort upload
  processing when the storage credential cannot administer it. Protected
  non-upload storage uses the Referer derived from
  `MAVE_CORE_INTERNAL_SECRET`; that value is sent only to matching configured
  storage origins. Remote-read failures still retry through an authenticated
  local storage download.
- `config :mave_core, :storage_object_max_concurrency, 8`: bounds concurrent
  object-storage operations, including HLS segment uploads
- `MAVE_FLOW_BOOSTER_BACKGROUND_RUN_CONCURRENCY`: active background-booster job
  safety ceiling per flow run; defaults to `6`. Work-conserving admission divides
  background capacity across demanding runs, so a lone run may borrow all six
  while busier periods reduce its current share automatically.
- `MAVE_ENCODING_BOOSTER_CHUNKING_THRESHOLD_SECONDS`: source durations above
  this value use bounded full-timeline fragmented-MP4 CPU-booster requests;
  defaults to `900` (15 minutes)
- `MAVE_ENCODING_BOOSTER_CHUNK_DURATION_SECONDS`: source duration encoded by
  each bounded request; defaults to `600` (10 minutes). Completed H.264 chunks are reusable across flow-step retries.
- `cdn_purge_endpoint`, `cdn_purge_headers`, `cdn_purge_paths`
- `callback_url` / `webhook_url` / `notify_webhook_url`
- `notify_webhook_headers`
- `flow_step_executor: "inline"` or `flow_disable_flame_steps: true`: force inline execution for all steps in a run

## Retry and recovery policy

- `MAVE_FLOW_STEP_MAX_EXECUTION_ATTEMPTS` defaults to `3`. It caps actual step
  executions within one automatic cycle, including Oban process recovery and
  transient FLAME or encoding-booster retries.
- `MAVE_FLOW_STEP_MAX_ORPHAN_RECOVERIES` defaults to `1`. It caps automatic
  requeueing after the worker job is no longer active.
- A status-only encoding-booster `502` or a closed booster transport uses a
  consistent five-execution budget across booster-backed steps, with bounded
  backoff. A `502` carrying a deterministic source error remains terminal.
- `MAVE_FLOW_STALE_STEP_RECOVERY_ENABLED` controls the recovery scanner.
- `MAVE_FLOW_STALE_STEP_RECOVERY_AFTER_MS` defaults to five minutes.
- `MAVE_FLOW_STALE_STEP_RECOVERY_LIMIT` bounds candidates processed per scan.

The same recovery scan also reconciles active runs whose old queued or scheduled
steps no longer have a live executor job. It leaves runs with executing steps or
live scheduled/retry jobs alone, and preserves every succeeded step and artifact.

The operator Retry action resets the per-cycle execution and orphan-recovery
budgets but does not erase the lifetime `step_runs.attempt` count. Oban attempts
are not an execution counter because fair-queue snoozes can increase them.

The encoding booster endpoint, credentials, and enabled state are intentionally
configured at deployment level rather than through run input. When enabled, all
eligible encodes use the booster. API callers cannot select external compute or
override its endpoint and credentials per job.

## Example (Forced FFmpeg + Strict)

```json
{
  "media_transcode_video_mode": "ffmpeg",
  "media_transcode_audio_mode": "ffmpeg",
  "media_extract_frame_mode": "ffmpeg",
  "media_generate_segments_mode": "ffmpeg",
  "media_generate_storyboard_mode": "ffmpeg",
  "media_transcode_video_strict": true,
  "media_transcode_audio_strict": true
}
```

## Notes

- These knobs exist to support encoder parity migration and deep debugging.
- They are not required for normal API usage.
- Expect this surface to shrink as parity work stabilizes.
