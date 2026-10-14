# Change: translate existing subtitle tracks

Branch: `feat/subtitle-translation`

Video settings now offer a source subtitle and multiple target languages. Each
language runs a small translation flow that preserves cue timing, adds only its
new subtitle, and refreshes HLS and the manifest. VTT, SRT, and timed transcription
JSON share the same source normalization. Existing languages, active duplicate
requests, unfinished video publishing, and stale video versions are rejected.

Translation publication and normal subtitle synchronization preserve independently
translated records, including delayed original-flow updates. Private HLS supports
the new nested object paths by resolving internal relative references strictly
inside the authorized embed. Direct request traversal remains rejected.

Dependencies: current Core `main`, its existing translation provider and storage
adapters. No Components package or SaaS change is required. Hosts can implement
the optional `can_translate_subtitles?/2` usage callback; absence remains allowed.
Provider calls retain existing configuration and do not introduce new credentials.

Migration: `20261014144645_add_subtitle_source` adds nullable `subtitles.source`.
New translated rows are tagged `translated`; historical rows remain unknown.

Validation used disposable PostgreSQL on port 55439, ClickHouse on port 8123, and
MinIO on port 19010, with `MIX_ENV=test` and `TMPDIR=/private/tmp`:

- `mix test test/mave_core/transcription/subtitle_translations_test.exs test/mave_core/flow_test.exs`:
  **116 passed**, including delayed normal synchronization, full re-finalization,
  provider/storage failures, and exact 50 ms cue timing.
- Full `mix test`: **1222 passed**, zero failures (seed `573110`, 38.9 seconds).
- `mix credo --strict`: passed, no issues.
- `mix precommit`: passed, including warnings-as-errors compilation, formatting,
  unused-dependency check, and compile-connected dependency audit.
- `mix security`: passed; existing low-confidence findings remain in unrelated
  files, with no dependency advisories or vulnerabilities.
- `mix security.enforce`: passed.
- `git diff --check`: passed.

The full suite includes independent-connection duplicate-request coverage,
dashboard multi-language submission and error feedback, parser cases, HLS storage
errors, version replacement, usage policy checks at request and execution time,
and authenticated nested-subtitle URLs with escape rejection. Translation provider
calls use deterministic test adapters; no paid provider or live infrastructure was
contacted. No pushes, pull requests, deployments, or package publications occurred.

See [Subtitle translation](subtitle_translation.md) for the flow, storage, and host
policy contract.
