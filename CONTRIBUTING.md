# Contributing to Mave Core

For versioning and maintainer release instructions, see [Releases](docs/releases.md).

Keep changes focused. Discuss large features and public API changes before
implementing them. To run Core without a development toolchain, use the
[self-hosting guide](deploy/self-hosted/README.md).

## Run with Docker

With Docker Compose 2.24.4 or newer, no host toolchain is required:

```sh
docker compose -f compose.dev.yaml up
```

Wait for “Mave is ready”, then open the setup link in your terminal. It fills in
the one-time code automatically; just enter your email. To show the link again:

```sh
docker compose -f compose.dev.yaml logs welcome
```

This starts the full local upload/playback stack with source reload, isolated
container dependencies, persistent development data, and a local email inbox at
[localhost:4000/dev/mailbox](http://localhost:4000/dev/mailbox). Request a login
link normally and open the inbox to use it. No SMTP or Google account is needed.
Initial startup installs and compiles dependencies; later starts reuse them.
Never expose development mode or its mailbox publicly.

Stop with `docker compose -f compose.dev.yaml stop`. Development uses a separate
Compose project and volumes from the release quickstart, but the same default
ports. Stop one before starting the other, or change `MAVE_HTTP_PORT`,
`MAVE_BASE_URL`, `MAVE_HTTPS_PORT`, `MAVE_MINIO_CONSOLE_PORT`, and the Docker subnet
as described in the self-hosting guide.

The older `docker-compose.yml` remains available for the host-toolchain workflow
below. Always select it explicitly with `-f docker-compose.yml`; the default
`compose.yaml` now starts the standalone release.

## Local test setup

Use only dedicated local services and synthetic data: tests create databases
and write media to MinIO. Never use production credentials or expose the
development services publicly.

Requirements:

- Docker with Compose v2; Elixir 1.19.4 and Erlang/OTP 28.2, as pinned in the
  [Dockerfile](Dockerfile).
- Node.js/npm, a C compiler, and Rust/Cargo.
- FFmpeg and FFprobe on `PATH`, with H.264 encoding (`libx264`).

From the repository root, in a shell without production configuration:

```sh
docker compose -f docker-compose.yml --project-name mave-core-dev up -d postgres clickhouse minio

export MIX_ENV=test
export POSTGRES_HOST=localhost POSTGRES_PORT=5433 CLICKHOUSE_HOST=localhost
export S3_ENDPOINT=http://localhost:9010
export AWS_ACCESS_KEY_ID=minioadmin AWS_SECRET_ACCESS_KEY=minioadmin
export AWS_REGION=us-east-1

mix deps.get
mix assets.setup
mix assets.build
mix ua_inspector.download --force
mix test
```

Wait for PostgreSQL (5433), ClickHouse (8123), and MinIO (9010) to be ready
before testing. If a port is occupied, use a separate development environment;
do not reuse another installation's services. Start only the three named
services, not the development Compose `app` service.

`mix test` prepares both database schemas and includes media integration tests.
Use `mix test test/path/to/file_test.exs` while iterating. If FFmpeg or MinIO
is unavailable, `SKIP_INTEGRATION=true mix test` runs the remaining tests;
report that limitation, not a complete passing suite.

## Run the dashboard in development

Keep those services and environment variables. In the same shell:

```sh
export MIX_ENV=dev
export MAVE_DOMAIN=http://localhost:4000

mix deps.get
mix ecto.create -r MaveCore.Repo -r MaveCore.ClickHouseRepo
mix ecto.migrate -r MaveCore.Repo -r MaveCore.ClickHouseRepo
mix assets.build
mix ua_inspector.download --force
MAVE_BOOTSTRAP_EMAIL=developer@example.com mix run -e 'MaveCore.Release.bootstrap_owner_from_env!()'
mix phx.server
```

Open the bootstrap link after the server starts; it expires after 15 minutes.
Rerun bootstrap with the same email if needed. Later login and invitation emails
appear at [localhost:4000/dev/mailbox](http://localhost:4000/dev/mailbox).
No SMTP or Google credentials are required. Never expose development mode or
its mailbox publicly.

Code and dashboard assets reload locally. Browser components still use the
hosted CDN, keeping them consistent with the self-hosted bundle. This setup
does not wire tusd and the public media proxy: use a separate
[self-hosted installation](deploy/self-hosted/README.md#install) for browser
upload/playback checks. Do not share its database volumes with development.

Stop just these development services, retaining data:

```sh
docker compose -f docker-compose.yml --project-name mave-core-dev stop postgres clickhouse minio
```

If you use the Compose `app` service for container-based development, it builds
the Dockerfile's `development` target, which includes Debian's FFmpeg and FFprobe
with H.264 encoding support. Rebuild it with `docker compose -f docker-compose.yml up -d --build app`
after changing the Dockerfile. Media tools are part of the image and survive
container recreation; no manual installation inside a running container is needed.
The production `final` target keeps its separately built, pinned FFmpeg version.

The Dockerfile also exposes `builder_base` (toolchain and compiled sandbox) and
`runtime_base` (FFmpeg, sandbox and runtime libraries) for applications embedding
Core. These stages contain no application release and require no private source.
Consumers should reuse them through BuildKit named contexts instead of copying
the FFmpeg build and dependency lists into another Dockerfile. The `development`
stage is a standalone toolchain image for mounted checkouts.

## Validate a change

Switch back to the test environment:

```sh
export MIX_ENV=test
mix test
mix credo --strict
mix security.enforce
mix precommit
git diff --check
```

`mix precommit` removes unused lockfile entries, formats, compiles with warnings
as errors, and runs the xref audit; it does not replace tests. Review generated
changes. The security commands are automated checks, not a complete assessment.

For installer, container, or media-flow changes, also run the
[isolated smoke test](deploy/self-hosted/README.md#automated-smoke-test) and the
[browser/email checks](deploy/self-hosted/README.md#verify-an-installation).
Documentation-only changes need command, link, and rendered-Markdown checks,
not a repeat of the full media journey.

## Preparing a change

- Explain the problem, reproduction, and intended behavior.
- Work on a task branch; keep unrelated changes and generated files out.
- Add deterministic regression tests close to the changed behavior.
- Preserve tenant isolation, upload/API authorization, player manifests,
  object paths, and webhook contracts.
- Update affected documentation and state which checks passed or were skipped.
- Never include credentials or customer data. Preserve attribution and licences
  for borrowed material; see [Third-party notices](THIRD_PARTY_NOTICES.md).

Keep discussions respectful. Report vulnerabilities privately via
[SECURITY.md](SECURITY.md), not public issues.

## Code and references

A workspace (`Space`) owns videos, collections, memberships, keys, and webhooks.
An `Embed` is a public placement, an `Asset` is its media identity, and a
`Video` is an uploaded version; this separation keeps embeds stable on replacement.

| Area | Location |
| --- | --- |
| Accounts, workspaces, media identity | `lib/mave_core/{accounts,spaces,assets,embeds,collections}` |
| Dashboard, authentication, HTTP API, sockets | `lib/mave_core_web` |
| Uploads, processing, and jobs | `lib/mave_core/{uploads,flow,workers}` |
| Storage, manifests, playlists, posters | `lib/mave_core/media` |
| Event ingestion and analytics | `lib/mave_core/{metrics,analytics}` |
| Product and analytics migrations | `priv/repo/migrations`, `priv/clickhouse_repo/migrations` |

PostgreSQL holds product state and flow execution records; ClickHouse holds
playback events; S3-compatible storage holds media. Browser components read
published manifests/media and send playback events to Core.

Technical reference, as needed:

- [Flow engine](docs/flow_engine.md) and [debugging](docs/flow_engine_internal.md):
  versioned templates, execution, retry behavior, and admin access.
- [Webhook delivery](docs/webhook_delivery_outbox.md): signed lifecycle events.
- [Encoding boosters](deploy/encoding-booster/README.md): optional remote compute;
  not needed for the single-host installation.
- [Analytics benchmarks](docs/analytics-benchmarks.md): tooling and its limitations.

Media parsers in the Docker images require Linux Landlock and seccomp. Native
macOS development has no OS parser sandbox; use Docker for untrusted uploads.
See [media security](docs/media_security.md) for limits, kernel requirements and
confinement tests.
