# Analytics date ranges and CSV exports

Both analytics endpoints accept an optional explicit UTC date range:

- `GET /v1/spaces/:space_hash/data`
- `GET /v1/videos/:embed_id/data`

The equivalent `/api/v1` routes remain supported. Existing API authentication,
space ownership and aggregate-data usage restrictions still apply. Read-only API
keys can retrieve analytics. No schema migration is required.

Supply `from=YYYY-MM-DD` and `to=YYYY-MM-DD` together. Both dates are inclusive;
the query uses midnight UTC on `from` through midnight UTC after `to`, exclusive.
`to` may be no later than the second calendar anniversary of `from` (February 29
clamps to February 28 in a non-leap anniversary year). `granularity` accepts
`day` (default), `week` (Monday start) or `month`. Supplying granularity without
both dates, an inverted range, invalid dates or an unsupported granularity returns
`422`. Weekly/monthly edge buckets include only the selected dates.

Requests without these parameters retain the existing response shape and
semantics. Range requests add `data.range`; the existing fields retain their
original today/month/year meanings:

```json
{
  "from": "2024-02-28",
  "to": "2024-03-01",
  "timezone": "UTC",
  "granularity": "day",
  "totals": {"views": 1, "watch_seconds": 4.0, "completion_rate": 0.4},
  "series": [
    {"date": "2024-02-28", "views": 1, "watch_seconds": 2.0, "completion_rate": 0.2},
    {"date": "2024-02-29", "views": 1, "watch_seconds": 2.0, "completion_rate": 0.4},
    {"date": "2024-03-01", "views": 0, "watch_seconds": 0.0, "completion_rate": null}
  ]
}
```

Watch time uses the established adjacent `play`/`pause` pairs. Each pair is
clamped to the requested interval and divided across UTC days before grouping.
A session counts as a view after at least one second of paired watch time within
the period. Total views deduplicate sessions over the full interval; a session
can count in multiple buckets, so bucket views need not sum to total views.
Unpaired play events do not contribute. To preserve sessions crossing either
range boundary, pairing considers the space's historical play/pause events;
queries have a 55-second server execution limit and a 60-second client timeout.
A failed range query returns `503`, rather than fabricated zero metrics.

Completion is the average maximum reached video fraction among qualifying
sessions with a finite positive recorded duration, clamped to 0–1. Boundary
crossings interpolate video position within the paired segment, so progression
after the selected end does not inflate completion. Unknown durations are
excluded and an empty denominator yields `null`. Space-level totals retain the
existing session grouping across videos; per-video exports group by both embed
and session. Shared-storage trial spaces return empty aggregate metrics to avoid
exposing combined trial traffic. All range query inputs use bound ClickHouse
parameters.

## Dashboard and export

The Data page includes UTC date inputs, a grouping selector and an Apply dates
button. The selection is stored in the page URL. Selected-period totals and a
bucket table appear above the unchanged existing dashboard. Reset clears the
selection. The initial form proposes the last 30 UTC dates without changing the
default dashboard query.

The selected period exposes a CSV download:

- `GET /:space_id/data/export.csv?from=...&to=...&granularity=...`
- `GET /data/export.csv?...` for the authenticated user's current space

These browser routes require the same authenticated membership and aggregate-data
usage permission as the Data page; API credentials do not authorize a browser
export. Responses are attachment downloads with `private, no-store` caching.
The UTF-8 CSV columns are:

```text
embed_id,title,views,watch_seconds,completion_rate
```

Every non-deleted video embed in the selected space is exported, including
archived videos and videos with no views. Collections and deleted embeds are
excluded. Results use keyset pagination in batches of 250 videos and HTTP
chunking, with no top-list limit. PostgreSQL queries remain in the Analytics
context. The query and calculation shared with the API also power CSV metrics.
CSV strings are quoted with doubled embedded quotes; spreadsheet formula
prefixes, including whitespace-prefixed formulas, are neutralized with an
apostrophe. Unknown completion is an empty field. A query failure before the
first batch returns `503`; a failure during download aborts the response instead
of reporting a complete export.

## Local validation

Run targeted tests against isolated PostgreSQL and ClickHouse services:

```sh
MIX_ENV=test mix test test/mave_core/analytics test/mave_core/analytics_test.exs \
  test/mave_core_web/controllers/api/data \
  test/mave_core_web/live/dashboard/data/index_test.exs
```

Coverage includes leap days, date validation, both interval boundaries,
cross-midnight sessions, daily/weekly/monthly empty buckets, completion handling,
tenant isolation, permission failures, both API route versions, unchanged legacy
responses, CSV quoting/formula protection and Data-page range/reset controls.

Validation on 2026-10-14 used disposable PostgreSQL (55439), ClickHouse (8123)
and MinIO (19010), with `TMPDIR=/private/tmp` on macOS and no production environment:

- Targeted analytics/API/Data LiveView tests: **43 passed**.
- Full `mix test`, including media integration tests: **1212 passed**.
- `mix credo --strict`, `mix security`, `mix security.enforce`, `mix precommit`
  and `git diff --check`: passed. Existing low-confidence Sobelow findings outside
  analytics remain unchanged.

Branch: `feat/analytics-range-export`, based on `origin/main` (`b55eae7`).
No feature dependencies, migration, push, PR, deployment or publication.
