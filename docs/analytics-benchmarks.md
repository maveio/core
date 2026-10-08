# Analytics benchmarks

Core includes `mix perf.clickhouse` for seeding synthetic playback events and
measuring the HTTP paths backed by ClickHouse:

- `GET /api/v1/spaces/:space_hash/data`
- `GET /api/v1/videos/:embed_id/data`

Use a dedicated, disposable local database and synthetic media identifiers.
Never point the task at production or an installation whose analytics you want
to retain. `--truncate` deletes the configured database's existing events.

## Important limitation

The current HTTP load generator does not send API credentials, while these
endpoints require authentication. Against a normal Core installation it will
measure rejected requests, **not analytics-query performance**. Check HTTP
status codes before interpreting any numbers. Do not disable authentication
to make a benchmark pass; authenticated request support needs to be added to
the task before using it for representative API measurements.

The options below document the existing tool for contributors working on that
benchmark. They are not a claimed performance result or a release acceptance
test. Use the [self-hosted smoke test](../deploy/self-hosted/README.md#automated-smoke-test) for
the authenticated product journey.

## Configuration and options

The task does not start the Phoenix server. It accepts `--base-url`, `--space`,
and `--embed-id`; use identifiers that exist in your synthetic fixture setup.
ClickHouse settings come from `CLICKHOUSE_HOST`, `CLICKHOUSE_PORT`,
`CLICKHOUSE_SCHEME`, `CLICKHOUSE_DATABASE`, `CLICKHOUSE_USER`, and
`CLICKHOUSE_PASSWORD`. `--db-name` selects the database used by seeding and
profiling; keep it aligned with the application's benchmark database.

| Option | Purpose |
| --- | --- |
| `--seed-sessions 200000` | Generate synthetic playback sessions |
| `--truncate` | Delete existing events before seeding; disposable databases only |
| `--target both` | Request both space and video endpoints |
| `--requests 2000 --concurrency 50` | Set workload size and concurrency |
| `--warmup 200` | Warm up before measuring |
| `--repeat 5 --tag baseline` | Repeat trials under a named tag |
| `--log-file .perf_clickhouse_runs.tsv` | Save results for comparisons |
| `--clickhouse-profile` | Inspect tagged queries in `system.query_log` |

Summarize previously recorded results:

```sh
mix perf.clickhouse --summary --log-file .perf_clickhouse_runs.tsv --limit 20
mix perf.clickhouse --best --log-file .perf_clickhouse_runs.tsv
```

These are end-to-end HTTP measurements, not isolated ClickHouse timings.
Keep runtime versions, fixtures, concurrency, and hardware consistent. Compare
repeated trials and account for cache state, background load, and Docker network
overhead. A high request rate with non-success responses is not an improvement.
