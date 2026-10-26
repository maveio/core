# Prepared analytics

Prepared sessions move repeated query work out of dashboard requests. Raw
`events` remain authoritative; this feature does not change their retention.
It is disabled by default.

## Enable and prepare

Apply both database migrations, then prepare existing events in bounded rounds:

```sh
mix ecto.migrate -r MaveCore.Repo -r MaveCore.ClickHouseRepo
mix analytics.sessions.backfill --limit 4 --rounds 100
```

Use `--space AAAAA` to prepare one space. Run one coordinator at a time; pause
the scheduled processor if a manual backfill would exceed your background
budget. Backfills are resumable and do not enable the reader. Do not run them
from application startup or deployment health checks.

After verifying preparation, enable the feature:

```sh
MAVE_ANALYTICS_SESSIONS=true
```

Reader and processor activation can be controlled separately:

| Setting | Purpose |
| --- | --- |
| `MAVE_ANALYTICS_SESSIONS` | Use prepared reads; defaults to false |
| `MAVE_ANALYTICS_PROCESSOR_ENABLED` | Run scheduled preparation; defaults to the reader setting |
| `MAVE_ANALYTICS_READ_SPACES` | Reader scope: `*`, comma-separated space hashes, or empty for none |
| `MAVE_ANALYTICS_PROCESS_SPACES` | Scheduled processor scope, with the same syntax |
| `MAVE_ANALYTICS_QUERY_THREADS` | Threads available to each analytics query |
| `MAVE_ANALYTICS_BUILD_MEMORY_BYTES` | Preparation query memory ceiling |
| `MAVE_ANALYTICS_READ_MEMORY_BYTES` | Read query memory ceiling |
| `MAVE_ANALYTICS_REFRESH_BUCKET_LIMIT` | Buckets prepared per round; defaults to 4 |
| `MAVE_ANALYTICS_CLEANUP_SPACE_LIMIT` | Spaces visited per cleanup round; defaults to 32 |
| `MAVE_ANALYTICS_CLEANUP_GENERATION_LIMIT` | Retired generations removed per space/round; defaults to 64 |
| `MAVE_ANALYTICS_READER_GRACE_SECONDS` | Retirement grace; defaults to 300 seconds, minimum 120 |

Both scope settings default to all spaces. They select processing behavior, not
access permissions. Direct `Sessions` calls explicitly request prepared data.
Application configuration can supply the equivalent `:analytics_sessions`
options; see [`Sessions.Config`](../lib/mave_core/analytics/sessions/config.ex).
Resource limits do not increase the server's available CPU, memory or disk.

## Publication and cleanup

Events are divided into sixteen session buckets per space. Each refresh builds
an immutable generation and publishes its PostgreSQL pointer only after all
ClickHouse representations are complete:

- `analytics_sessions`: ordered events and paired playback segments.
- `analytics_session_years`: compact year totals, source dimensions and unique-watch intervals.
- `analytics_session_reports`: per-video daily watch totals and completion data.
- `analytics_overview_days`: daily engagement summaries with exact boundary data.
- `analytics_overview_views`: per-video session totals for reads within a complete interval.

Initial readers require all sixteen current-format pointers, including empty
buckets. Until then they return `:preparing`; database failures return
`:analytics_unavailable`. Existing complete generations remain readable during
refreshes. Failures do not publish partially built data. The engagement overview
also waits for its readiness marker; existing prepared reads remain available
while an older installation builds those additional summaries.

The processor detects new, changed and late events. Future-dated events become
visible when their time arrives. Cleanup reclaims retired generations after the
reader grace period. Pausing the processor retains stale-but-complete reads;
cleanup can still run while the reader is enabled.

Keep processing rounds short enough for cleanup to run. Monitor ingestion,
publication age, read latency, memory and physical disk usage together. Retired
and inactive parts consume space as well as the active generation. Long-running
exports need a pinned snapshot or an appropriately sized grace period; ordinary
prepared reads have at most a 20-second client deadline.

## Existing installations and source changes

Inventory and per-session revision projections speed up source discovery.
Missing projection data affects performance, not correctness. Materializing
existing parts is optional maintenance and can require significant time and
space:

```sh
mix analytics.sessions.backfill --materialize-inventory --materialize-session-revisions --limit 4 --rounds 100
```

Source deletion, copying or restoration must invalidate affected prepared data
with `Sessions.invalidate/1` under the caller's existing authorization, then
rebuild it. Do not reuse a retired space identifier before invalidation succeeds.
Normal event arrival needs no explicit invalidation.

## Query semantics

Period views apply the one-second watch threshold per session over the whole
window; adding daily view counts gives a different result. Per-video views
apply it separately to each session/video pair. Ranges use an exclusive end
instant and clip segments at their boundaries. Partial days, future events and
incomplete daily reports use precise segment calculations where needed.

For function signatures, options and return values, see the docstrings in
[`Analytics`](../lib/mave_core/analytics.ex) and
[`Sessions`](../lib/mave_core/analytics/sessions.ex). Keep custom queries scoped
to both the space and its active generations. A prepared overview's performance
does not guarantee that a different report is fast; test its actual query.
