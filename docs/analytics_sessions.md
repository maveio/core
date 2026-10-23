# Prepared analytics sessions

Prepared sessions separate event ingestion from dashboard query work. The raw
`events` table remains authoritative and is not deleted or rewritten by the
session processor. Enable the reader/worker with `MAVE_ANALYTICS_SESSIONS=true`
after migrations and the initial backfill have been verified. It defaults off. Query thread and memory ceilings can be configured for the
installation, for example:

```elixir
config :mave_core, :analytics_sessions,
  enabled: true,
  query_threads: 2,
  build_memory_bytes: 1_073_741_824,
  read_memory_bytes: 536_870_912
```

Readers and background processing can be switched independently. An unset
`processor_enabled` follows `enabled` for compatibility. Set it explicitly to
prepare/catch up while readers still use the original implementation, or to
pause processing while retaining the last complete prepared results.
Scheduled cleanup runs while either the reader or processor is enabled; pausing
the processor stops rebuilds, not reclamation of superseded generations.

```elixir
config :mave_core, :analytics_sessions,
  enabled: true,
  processor_enabled: true,
  read_spaces: ["AAAAA", "BBBBB"]
```

`read_spaces` defaults to `:all`. It only selects the prepared reader; other
spaces retain the original reader, and the processor can still prepare all
spaces. An empty list selects no prepared readers. It does not alter access
control. Direct `Sessions` calls remain explicit prepared-data operations.

The worker can be restricted separately with `process_spaces: ["AAAAA"]`, or
`MAVE_ANALYTICS_PROCESS_SPACES`. It defaults to all spaces, accepts `*` for all
and an empty value for none. Use this during a capacity-limited rollout so the
worker does not begin preparing the entire installation. Explicit per-space
maintenance/backfill calls remain independent of this worker setting.

The corresponding runtime variables are `MAVE_ANALYTICS_SESSIONS`,
`MAVE_ANALYTICS_PROCESSOR_ENABLED`, `MAVE_ANALYTICS_READ_SPACES` (comma-separated
hashes, `*` for all, empty for none), `MAVE_ANALYTICS_BUILD_MEMORY_BYTES`,
`MAVE_ANALYTICS_READ_MEMORY_BYTES`, `MAVE_ANALYTICS_QUERY_THREADS`,
`MAVE_ANALYTICS_REFRESH_BUCKET_LIMIT` (default 4), and
`MAVE_ANALYTICS_CLEANUP_SPACE_LIMIT` (default 32),
`MAVE_ANALYTICS_CLEANUP_GENERATION_LIMIT` (default 64 per space/round), and
`MAVE_ANALYTICS_READER_GRACE_SECONDS` (default 300; minimum 120).
Invalid values fail startup rather than silently changing the activation scope.

Limits remain bounded by ClickHouse's own server settings; increasing these
values does not increase available server memory.

## Storage and publication

`analytics_sessions` stores one row per space/session in an immutable generation.
It retains ordered events and paired play/pause segments, including video IDs,
positions, duration and source dimensions. A session shared by multiple videos
stays in the same bucket. This preserves legacy space-level counting while
allowing per-video reports to group separately.

The build records the source window's event ordinal before collecting arrays,
so equal timestamps retain the playback pairing used by the legacy window
queries. Timestamp ties have no independent event ID in the source schema;
the prepared layer does not invent a new ordering policy for them. Large
per-video arrays are combined element by element to avoid the aggregate
function's nested-array element size limit.

`analytics_session_years` stores compact per-session calendar-year totals,
first-event source dimensions and watch totals combined per day for the common
overview. Repeated same-day segments occupy one day entry while retaining the
original segment-start attribution and per-session view thresholds. It also
stores deduplicated integer watch intervals per day for the common unique-watch
query. Deduplication preserves the earliest-day attribution across periods;
historical within-day reads retain the original segment calculation. Copying
an older generation combines its day entries, and format upgrades rebuild the
compact year summaries from stored sessions without reordering raw events.

`analytics_session_reports` stores compact per-session/video/day watch totals
and completion maxima. Calendar-aligned period series use these summaries,
including a current partial day only when the snapshot has no future events.
Historical partial-day boundaries and per-video mode use bounded segment
queries. Sessions containing intervals longer than the supported report window
are marked incomplete and use the segment path instead of expanding unbounded
day arrays. Version-3 snapshots can gain reports by reusing their existing
session data. All three tables are built before a generation is published. Date-range
queries retain the full segment representation; they do not sum daily view
counts to obtain period views.

Sixteen deterministic session buckets bound each publication. Initial builds
read the bucket's source events. Subsequent refreshes compare per-session
counts/fingerprints, copy unchanged prepared rows into a new immutable
partition, and recalculate only changed sessions. Session rows, compact year summaries and day reports are copied together. More than 50,000 changed sessions trigger the bounded full-bucket path. PostgreSQL's
`analytics_session_buckets` publishes one active generation per space/bucket.
An advisory transaction lock serializes publication and invalidation within a
space. A failed ClickHouse insert never changes the active pointer. A retry
uses a new generation, so partial inserts cannot double-count published data.
Initial readers wait for all sixteen bucket pointers, including empty buckets.
Subsequent readers use the last complete bucket versions during refresh.
Format versions prevent incompatible older generations from being read.
Future-dated events are excluded from summaries until their time arrives; the
published metadata records a refresh deadline so they become visible without
requiring another insert. A materialized per-session deadline also lets the
processor refresh only those sessions. Between refreshes, current overview and
date-aligned time-series queries combine compact rows with detailed calculations for
the affected sessions; one newly visible event does not force a detailed scan
of the entire space. Historical and partial-day reads retain precise segment
calculations.

The `analytics_session_inventory` projection summarizes source row counts and
field fingerprints. It lives inside the raw MergeTree table, so it follows
normal inserts and source mutations without an application-side dual write.
Late events are detected by their arrival in the source, not by their event
timestamp. A snapshot records the count/fingerprint of the exact rows read by
its build; changes racing with that build remain different at the next poll.
Identical replacement rows need no rebuild; same-count changes to event fields
change the fingerprint. As with any non-cryptographic checksum, collisions are
theoretically possible.

The `analytics_session_revisions` projection stores the same aggregate
revision per session. It identifies exactly which sessions need recalculation
without sorting all historical events again. These projections contain
aggregate metadata; they do not reorder the raw event reads. This matters for
legacy events with identical timestamps and no independent sequence number.
Both projections are maintained by ClickHouse inserts and source mutations.

The projections are optimizations, not correctness dependencies. Existing parts
without them are scanned until they are explicitly materialized. Initial migration
does not perform an unbounded historical backfill during deployment.

## Operation

Run commands from the hosting application (for example the SaaS application):

```sh
mix ecto.migrate
mix analytics.sessions.backfill --materialize-inventory --materialize-session-revisions --limit 16 --rounds 100
# Optional: prepare one tenant without changing the reader activation scope.
mix analytics.sessions.backfill --space AAAAA --limit 1 --rounds 16
```

Apply both the PostgreSQL and ClickHouse migrations through the installation's
usual migration command. The optional projection materialization can take time
and disk space; run it as an explicit maintenance/backfill step. Backfill can be
stopped and resumed. The command publishes at most `--limit` buckets per round
and stops when caught up or when `--rounds` is exhausted. It does not enable the
feature or alter event retention.

Run only one backfill coordinator at a time. Pause the scheduled processor while
running a manual backfill if aggregate background concurrency must stay at one.
The space option bounds rebuilds, but inventory discovery can still read the
whole source until the projection is materialized. Do not include projection
materialization or historical backfill in application startup or deployment
health checks.

The minute worker runs on the `analytics` queue with one job per node and a
distributed Oban uniqueness constraint while active. It prioritizes unpublished
and oldest buckets. Source changes coalesce into bucket rebuilds rather than
creating one job per event. The default round handles four buckets; tune the
configurable batch limit against measured build duration and freshness targets.
Copying unchanged rows uses a single stream and bounded byte-sized blocks,
with a separate 512 MiB maximum within the configured build limit. This leaves
more headroom for raw-event merges. Very large individual rows still need to
fit in the copy budget; failure preserves the published generation.
Keep rounds short enough that cleanup on the same queue can run regularly.

The minute cleanup worker visits up to 32 spaces per round, oldest first. It
collects eligible retired generations per space. Each immutable generation has
its own partition (keyed by space and generation), so cleanup drops whole
partitions instead of rewriting surviving rows. Different generations never
merge together. Automatic merges are disabled on these three immutable tables;
a generation has a bounded set of insert parts and is retired as a unit. This
avoids background merge amplification during repeated refreshes. PostgreSQL records when a version
was replaced; the five-minute default reader grace period starts then, not when the version
was originally built. Discovery gives unpublished crash remnants a fresh grace
period. Active generations are excluded again under the publication lock.
Deletion must succeed on all three tables before retirement records are removed;
failures are safe to retry. ClickHouse can retain inactive files after a drop;
measure physical bytes as well as active rows when planning disk headroom.
The number of partitions grows with nonempty buckets and retained generations;
include that metadata cost when testing installations with many spaces.
Prepared read queries have at most 20-second client
deadlines; consumers of `generations/1` must use the returned pointers promptly,
within the configured grace period. Long-running exports need their own pinned
snapshot or a larger configured grace period. More retained generations consume
more disk; do not increase the grace period without measuring storage growth.

Raw source deletion/copy callers must call `Sessions.invalidate/1` under their
existing lifecycle authorization after changing the source. This hides prepared
data immediately and removes its generations; remaining source data rebuilds
from the next inventory. In particular, retired tenant identifiers must not be
reused before invalidation succeeds. Normal event arrival needs no callback.

## Query interfaces

- `Sessions.data(hash)` returns the dashboard fields without calculating unique
  watch time. `include_unique: true` adds the existing API field.
- `Sessions.range_data(hash, from, to, granularity: :day | :week | :month)` returns
  a map keyed by date strings, with `""` holding whole-period totals. `to` is
  exclusive; the caller converts an inclusive last date to next-day midnight.
- `mode: :videos, embed_hashes: hashes` returns per-video totals for a bounded
  export batch of at most 250 hashes. Empty hashes select all videos.
- `Sessions.generations(hash)` exposes the immutable generation list for shared
  future reports. Every query must also constrain `space_hash`.

Range metrics preserve sessions across midnight and clip segments at range
boundaries. Whole-period views are calculated independently of daily views;
they must not be obtained by adding daily counts. Completion excludes unknown
durations. Legacy overview queries retain their existing year/date attribution.
Unique watch time unions watched integer intervals instead of allocating one
row per watched second, retaining earliest-observation attribution.

An incomplete initial backfill returns `:preparing`; database failures return
`:analytics_unavailable`. The API reports 503 with Retry-After; the dashboard
shows preparation state and polls again. Neither substitutes fabricated zero
metrics for an unavailable prepared result.

## Analytics feature integration

Top-list and period-overview features should consume the prepared generation
and segment interfaces instead of adding `leadInFrame` scans of raw events.
Date-range/CSV code can use `range_data/4`; retain its existing metadata joins,
authorization, output escaping, and bounded export pagination. Device/browser
and additional source panels should share a session aggregation in one query.
The stored tuples include OS, source URL, duration and video positions for
engagement, completion and website reports. This does not merge those feature
branches or change their public API contracts.

Restoring raw events without the matching prepared data requires invalidating
the published metadata and rerunning the backfill. Prepared data is derived and
can always be rebuilt from the raw source.

Publication remains bucket-scoped, but normal recomputation is session-scoped.
Unchanged event arrays and year summaries are copied without sorting again;
changed sessions retain the same raw-event pairing query as full backfills.
Large change sets and due future events use the full-bucket fallback. Measure
both paths, including very large individual sessions.

Measure sustained ingestion and reclamation, not only isolated read latency.
Repeated immutable generations temporarily amplify storage even when their
contents are reused. Cleanup and processing have independent bounded budgets;
measure complete sweep time, inactive parts and retained generations at the
intended tenant count. Do not enable broadly when processing lag or physical
storage grows without bound. Deployment-specific budgets and rollout decisions
belong to the hosting application.
