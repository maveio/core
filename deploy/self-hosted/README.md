# Self-hosting Mave Core

A single-host Docker bundle: Core, PostgreSQL, ClickHouse, MinIO, tusd, and Caddy.
It runs a production release with local FFmpeg processing, without source mounts
or compilation at startup. No Kubernetes cluster or encoding booster is needed.

## Browser-guided quickstart

From the **repository root**, with Docker Compose 2.24.4 or newer:

```sh
docker compose up
```

Open `http://localhost:4000`, enter your owner email and the one-time code printed
in the “Mave is ready” terminal message (`docker compose logs welcome`
shows it again). Setup creates the first workspace
and signs you in immediately. It is permanently closed after completion, and
is never offered when an account already exists. Only the one-time setup code appears in the startup log; database credentials
and application secrets are never printed. The setup link carries the code in a URL fragment, which is removed immediately
in the browser. It is only submitted in the protected setup form, never in
request URLs or referrer headers.

This path builds Core and storage from source on the first run, generates unique
secrets automatically, runs migrations, and waits for service readiness. No host
OpenSSL, manual database creation, or environment file is needed. Use
`docker compose up -d` for subsequent starts, and `docker compose stop` to stop.
Data and generated secrets live in project-scoped Docker volumes, including
`setup_data`. Back up **both** secrets and data, plus your root `.env` if you
supply configuration overrides. `docker compose down -v` deletes
them and is only appropriate for intentionally discarding an installation.

The default HTTP/HTTPS ports bind to `127.0.0.1`. To use another local HTTP port:

```sh
MAVE_HTTP_PORT=4100 MAVE_BASE_URL=http://localhost:4100 docker compose up -d
```

Persist custom settings in a private `.env` in the repository root and use the
same settings on subsequent starts. For public hosting, set these before
starting (replace the example hostname and configure its DNS):

```dotenv
MAVE_BASE_URL=https://video.example.com
MAVE_CADDY_ADDRESS=video.example.com
MAVE_BIND_ADDRESS=0.0.0.0
MAVE_HTTP_PORT=80
MAVE_HTTPS_PORT=443
```

Caddy handles certificates. The setup page displays the configured address;
it does not rewrite DNS, certificates, or running container configuration.
Keep development (`compose.dev.yaml`) local; use the release for public hosting.

### Email and later login

The first browser login works without SMTP. For subsequent logins and team
invitations, put the SMTP settings from [Email and registration](#email-and-registration)
in your root `.env`, then run `docker compose up -d` to apply them. The setup
form explains whether email is configured. SMTP delivery still needs testing
with your provider before inviting users.

If you have not configured email, request a fresh private owner login link with:

```sh
docker compose run --rm -e MAVE_BOOTSTRAP_EMAIL=you@example.com bootstrap
```

Use the **same email** you entered during setup. For development, use
`docker compose -f compose.dev.yaml` in all commands and read login messages at
`/dev/mailbox` instead. No external mail provider is needed there.

### Existing installations and embedding Core

The quickstart is opt-in through its Compose overlay. Normal Core deployments
have `MAVE_INSTALLATION_SETUP=false` by default. Do not turn it on in an embedding
application. The setup HTTP routes additionally require Core's own endpoint,
so forwarded SaaS traffic cannot use them even with inherited setup settings.
No SaaS configuration or commercial provisioning is changed.

Keep existing scripted installations on their current directory, project name,
volumes, and `.env`. Do not switch startup paths to upgrade an existing install.
The instructions below describe that original scripted path; quickstart users
run Compose from the repository root instead.

## Install

Requirements: Docker with Compose v2 on Linux or macOS, `openssl`, and `lsof`
or `ss`. Allow at least 4 CPU cores, 8 GB RAM, and 20 GB free disk for evaluation,
plus capacity for media. Configure SMTP for email login and team invitations.

From the Core repository root:

```sh
docker build --target final -t mave-core:self-hosted .
cd deploy/self-hosted
./install.sh --image mave-core:self-hosted --owner-email owner@example.com
./verify.sh
```

Open the private, 15-minute login link printed by the installer. The default
origin is `http://localhost:4000`; HTTPS uses port 4443 and the MinIO console
uses loopback port 9001. Use `--http-port`, `--https-port`, and
`--minio-console-port` to choose free ports.

The installer generates a mode-0600 `.env`, creates the databases and first
workspace, and starts the services. Rerunning it reuses secrets and data and
can issue another login link for the same owner. It refuses conflicting image,
origin, or port options when `.env` already exists: edit the existing
configuration deliberately, rather than deleting it and regenerating secrets.

Build locally as above unless you have a verified release image. The installer's
default registry reference is not a promise of a publicly available image.

All commands below run from this directory unless stated otherwise.
[.env.example](.env.example) lists the available operator settings; let the
installer generate secrets rather than copying its placeholder values.

### Networking and a second installation

Caddy exposes the public routes; the app, tusd, databases, and MinIO S3 service
remain on the Docker network. The MinIO admin console binds to loopback.
Use a firewall when the installation should be accessible only locally.

The default subnet is `172.30.0.0/24`; Caddy uses `172.30.0.254`, away from
the first automatically assigned service addresses. If it conflicts, set
`MAVE_DOCKER_SUBNET` and a matching `MAVE_CADDY_INTERNAL_IP` in `.env`
before starting. Keep Caddy's trusted-proxy address aligned with these settings.

MinIO and its client are built from pinned upstream source releases using
`../minio/Dockerfile`; the installer builds them automatically because the
community registry images are no longer publicly available.

For a separate browser-test installation, copy `deploy/self-hosted` and
`deploy/minio`, preserving their sibling layout; set a unique
`COMPOSE_PROJECT_NAME`, free host ports, and a non-overlapping subnet.
Set the subnet variables in the environment for the first installer run; the
installer persists them in `.env`. Never reuse another installation's
secrets or volumes. For automated checks, the [smoke script](#automated-smoke-test)
handles isolation for you.

## HTTPS

Point the hostname's A/AAAA records at the host and allow TCP 80/443 and UDP 443.
For a new installation, use:

```sh
./install.sh \
  --image mave-core:self-hosted \
  --base-url https://video.example.com \
  --http-port 80 --https-port 443 \
  --owner-email owner@example.com
```

Caddy obtains and renews certificates. With an existing TLS-terminating reverse
proxy, route to the Compose HTTP port and preserve `Host`,
`X-Forwarded-Host`, and `X-Forwarded-Proto`.

## Email and registration

Before relying on email login or inviting teammates, configure SMTP in `.env`:

```dotenv
MAVE_MAILER_ADAPTER=smtp
MAVE_EMAIL_FROM_NAME=Mave
MAVE_EMAIL_FROM_ADDRESS=mave@example.com
SMTP_RELAY=smtp.example.com
SMTP_PORT=587
SMTP_USERNAME=mave@example.com
SMTP_PASSWORD=replace-me
SMTP_TLS=always
SMTP_SSL=false
```

Supply both SMTP credentials or neither. `SMTP_TLS` accepts `always`,
`if_available`, or `never`. Apply this and other configuration changes with:

```sh
docker compose --env-file .env -f compose.yml up -d app upload caddy
```

Public signup is disabled by default; teammates can join through invitations.
To intentionally open signup, configure SMTP and set a finite account limit:

```dotenv
MAVE_PUBLIC_REGISTRATION_ENABLED=true
MAVE_PUBLIC_REGISTRATION_MAX_USERS=100
```

Existing users can log in when signup is disabled or its limit is reached.

## Media and storage

Direct uploads and remote imports share a 20 GiB per-file hard limit.
Set `MAVE_MEDIA_INPUT_MAX_BYTES` in `.env` to change it, then recreate both
`app` and `upload` with the command above. Uploads must declare their size;
this limit does not replace storage capacity monitoring.

Browsers load `@maveio/components` and `@maveio/data` from
`cdn.video-dns.com` by default. Media and analytics stay on your installation.
No local component build is needed, but browser clients need outbound HTTPS/DNS.
`MAVE_COMPONENTS_BASE_URL` and `MAVE_COMPONENTS_SRC` can override the bundle;
this distribution does not vendor one.

### Storage compatibility

The bundle pins MinIO, which is exercised by the upload, processing, bucket-policy,
CORS, and playback checks. Its upstream container distribution is archived;
pinning a version does not replace a maintenance and security review.

A different S3-compatible store must support:

- tusd multipart uploads, completion hooks, and idempotent bucket creation;
- private upload objects and publicly readable processed HLS, posters,
  subtitles, and player assets;
- bucket-policy/CORS synchronization, signed private reads, and FFmpeg input;
- compatible deletion, cleanup, and retries.

Changing the store requires coordinated Core, tusd, storage initialization, and
public-media routing configuration, not just changing the container image.
Garage is not yet validated as a drop-in replacement: Core's bucket-policy
requirements need an adapter or an authenticated media gateway. Before switching,
verify the full product journey on both amd64 and arm64.

## Verify an installation

Run `./verify.sh` for service readiness, then check the browser journey using
demo data:

1. Sign in with the bootstrap link and check the selected workspace.
2. Upload a small MP4 with audio; wait for processing to succeed.
3. Reload it, play it with sound, and check the generated embed in a separate
   browser session. It should work without dashboard authentication.
4. Open Data after playback and allow a few seconds for analytics to appear.
5. With SMTP configured, request a new email login and invite a teammate from
   Settings → Team. Check delivery, the link's origin, and access to the workspace.

For installer changes, also check that `.env` is mode 0600, reruns preserve
secrets/data, and only Caddy plus the loopback MinIO console publish host ports.

### Automated smoke test

From the Core repository root:

```sh
./deploy/self-hosted/smoke.sh
# Or test an already-built local image:
./deploy/self-hosted/smoke.sh --image mave-core:self-hosted
```

The script builds a release and checks bootstrap/login, API authentication and
CRUD, signed tus uploads, processing, manifest/player delivery, full HLS video
and audio decoding, measured audio peaks, private upload-bucket denial, and
analytics readback.

It needs Git, `openssl`, and Docker Compose v2 with `!reset` support. Use a
selected Docker context, not `DOCKER_HOST`. Every run uses its own project,
network, secrets, and volumes; it publishes no host ports or reuses existing
environment files. Its services, volumes, and network are removed afterward;
the image and build cache remain. Failures, including cleanup failures, return
a nonzero exit status.

The printed temporary directory contains image identity and private diagnostics.
Do not publish it: logs may contain disposable credentials and login links.
A supplied image is pinned by ID but is not assumed to match the checkout.
This checks protocols, not the installer CLI, browser JavaScript/interactions,
or SMTP delivery; use the manual checks above for those.

## Operations and upgrades

State lives in named PostgreSQL, ClickHouse, MinIO, and Caddy volumes.
Keep `.env` private and backed up with the data. Useful commands:

```sh
docker compose --env-file .env -f compose.yml ps
docker compose --env-file .env -f compose.yml logs -f app upload
docker compose --env-file .env -f compose.yml run --rm \
  -e MAVE_BOOTSTRAP_EMAIL=owner@example.com bootstrap
docker compose --env-file .env -f compose.yml stop
```

The last command stops services while retaining data. Do not use `down -v`
unless you intend to delete this installation's volumes.

Before upgrading, back up the databases and media, retain the old image/config,
and plan for downtime. Build a new locally tagged image or pull a verified
release, then set `MAVE_CORE_IMAGE` in `.env` to that version.

Core refuses to start without a private Erlang distribution cookie of at least
32 characters. Installations created before this requirement have none, and the
build-time cookie baked into an image is shared by everyone who uses that
image. Rerunning `./install.sh` adds a cookie to an existing `.env`, or add one
yourself:

```sh
grep -q '^RELEASE_COOKIE=' .env ||
  printf 'RELEASE_COOKIE=%s\n' "$(openssl rand -hex 32)" >> .env
```

Stop writes, run migrations, and bring the services back:

```sh
docker compose --env-file .env -f compose.yml stop app upload
docker compose --env-file .env -f compose.yml run --rm migrate &&
  docker compose --env-file .env -f compose.yml up -d
./verify.sh
```

Repeat the browser checks afterward. Do not assume the old image can run against
a migrated schema; recovery may require restoring the matching backups.
This bundle does not provide high availability, automated backups, or
zero-downtime migrations.

## Media processing security

The bundled image confines FFmpeg and FFprobe, and Compose applies resource limits
and a read-only root filesystem. The host must support Landlock ABI 3 and seccomp;
unsupported hosts fail before media parsing. Review the [media security guide](../../docs/media_security.md)
for resource sizing, network isolation, Kubernetes controls and remaining risks.
