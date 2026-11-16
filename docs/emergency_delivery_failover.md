# Emergency delivery failover

Move all public video delivery to an independent provider with one DNS change
when the primary storage or CDN provider is unavailable or compromised. The
switch is made by an operator; nothing here fails over automatically.

Public playback only reads static files: a player fetches
`<media host>/<embed>/manifest.json` and the playlists, segments and captions
next to it. A second provider that holds the same files under the same URLs can
therefore take over without changing a single embed.

```text
viewers ── DNS: delivery record ──┬─▶ primary CDN ──▶ primary storage
                                  │                        │ mave.delivery_standby sync
                                  └─▶ standby edge ──▶ standby storage
```

## What must be ready beforehand

| Requirement | How it is met |
| --- | --- |
| A usable media copy | `sync` copies the public media of every space into same-named buckets at the standby. |
| Compatible URLs | A standby edge answers the public media hostnames and maps them onto those buckets. [`deploy/delivery-standby/Caddyfile`](../deploy/delivery-standby/Caddyfile) is a reference. |
| Access controls | Only public media is copied. Each standby bucket gets the space's CORS origins and its public or hotlink-protected read policy. |
| A certificate | The standby edge holds a valid certificate for every media hostname before the switch. Use a wildcard certificate from a DNS challenge; an HTTP challenge cannot succeed while DNS still points at the primary. |
| One record to change | Every media hostname is a `CNAME` to one delivery record with a TTL of 60 seconds or less. |
| Independence | The standby storage, its edge and the DNS zone use other providers, accounts and credentials than the primary. |
| Proof | `check` reports `READY`, and the [drill](#rehearse-the-switch) has been run. |

`sync` never copies media that is not public: embeds that are private,
changing visibility, or deleted. Media that stops being public is removed
from the standby by the next run, before anything is copied. A space with
hotlink protection is skipped when the standby cannot apply its bucket policy.

## Configure the standby

| Variable | Purpose |
| --- | --- |
| `MAVE_DELIVERY_STANDBY_S3_ENDPOINT` | S3 endpoint of the standby. Setting it enables the feature. |
| `MAVE_DELIVERY_STANDBY_S3_ACCESS_KEY`, `MAVE_DELIVERY_STANDBY_S3_SECRET_KEY` | Credentials that may create buckets and write objects and bucket policies. |
| `MAVE_DELIVERY_STANDBY_S3_REGION` | Signing region. Default `us-east-1`. |
| `MAVE_DELIVERY_STANDBY_BUCKET_PREFIX` | Bucket prefix at the standby when `space-` is not available there. The edge maps `space-<hash>` onto it. |
| `MAVE_DELIVERY_STANDBY_OBJECT_ACL` | Set to `true` when the standby needs a `public-read` ACL on each object. |
| `MAVE_DELIVERY_STANDBY_EDGE_URL` | Address where the standby edge answers before DNS points at it, such as `https://203.0.113.10`. Enables the URL probes. |
| `MAVE_DELIVERY_STANDBY_STATUS_BUCKET` | Private bucket for the report of the last sync. Default `mave-delivery-standby`. |
| `MAVE_DELIVERY_STANDBY_MAX_AGE_SECONDS` | Oldest sync that still counts as ready. Default 86400. |

## Keep the copy current

```sh
bin/mave_core eval 'MaveCore.Release.delivery_standby("sync")'
bin/mave_core eval 'MaveCore.Release.delivery_standby("check")'
```

From a checkout, use `mix mave.delivery_standby sync` and
`mix mave.delivery_standby check`. Both accept `--space HASH` and `--json`;
`sync --dry-run` reports the plan without changing the standby.

Run `sync` on a schedule, for example hourly from cron or a Kubernetes CronJob.
The interval is the amount of recent media a switch can lose. Run `check` after
it and alert on a non-zero exit status.

`check` compares both copies, reads the age of the last complete sync and, with
an edge URL, requests real media from the standby under the public hostname: a
manifest, a byte range of the largest file, a request without `Referer` for
hotlink-protected spaces, and a private embed that must be refused. Over HTTPS
this also proves the certificate.

A sync does not delete on its own when more than a quarter of a space vanished
from the primary. A wiped or tampered primary then leaves the standby intact;
confirm intended mass deletions with `sync --force-deletes`.

## Switchover procedure

1. **Decide.** Switch when the primary cannot deliver and no recovery is in
   sight, or when its content can no longer be trusted.
2. **Freeze the copy** if the primary may be compromised: stop the scheduled
   `sync`, so changed media is not copied over the last good state.
3. **Confirm the standby.** Run `check`. If Core itself is down, read
   `status.json` in the status bucket with the standby provider's own tools.
4. **Change the delivery record** to the standby edge. This is the switch.
5. **Verify** from outside your network:

   ```sh
   dig +short space-<hash>.<media host>
   curl -sI https://space-<hash>.<media host>/<embed>/manifest.json
   ```

   The reference edge answers with `X-Mave-Delivery: standby`. Play one embed
   on a customer page.
6. **Tell customers** what is degraded, using the list below.

To move back, verify the primary, change the delivery record back and resume
the scheduled `sync`. The standby is never written to by viewers, so there is
nothing to copy back.

## What DNS alone cannot solve

| Not covered | Effect during a switch |
| --- | --- |
| Private playback | Signed URLs point at the primary's storage hostname, which DNS cannot redirect, and tokens are verified by Core. Private videos stay unavailable. |
| Everything Core serves | Uploads, the API, the dashboard, playback analytics and on-demand poster images (`MAVE_IMAGE_BASE_URL`) depend on the application and its databases. |
| The player script | Embeds load it from `MAVE_COMPONENTS_BASE_URL`. If that URL uses a media hostname, the standby must serve the script too; `sync` does not copy it. |
| Changes since the last sync | New or replaced videos are missing. A video that was deleted or made private after the last sync is still public on the standby until the next run, or until it is removed there by hand. |
| Cached DNS answers | Resolvers keep the old address for the record's TTL, and browsers for about a minute regardless of it. A player that was mid-playback may need a page reload. |
| A zone at the failed provider | If the primary also hosts the DNS zone, the record cannot be changed. Moving name servers at the registrar takes hours. |
| Hostnames outside the delivery record | Customer domains that point at a provider hostname instead of the delivery record do not follow the switch. |
| Object metadata | Copies keep the content type. Cache headers come from the standby edge. |
| A cold cache | The standby starts without cached media, so its storage serves every first request. |

## How long recovery takes

| Phase | Duration |
| --- | --- |
| Noticing the outage and deciding | Depends on monitoring and on who may decide. Usually the largest part. |
| Changing the record | Seconds, through the DNS provider's API or console. |
| Resolvers pick up the change | At most the record's TTL. |
| Browsers with a cached address | About one more minute. |

In the local drill, with a TTL of 5 seconds, a viewer behind a caching resolver
was served by the standby 2 seconds after the record changed. Chrome kept the
old address and recovered about 50 seconds after the change. With a TTL of 60
seconds, expect most viewers back within two minutes of the DNS change.

## Rehearse the switch

The drill runs two independent storage servers, their edges, an authoritative
DNS zone and a caching resolver in Docker. Core syncs and checks the standby
with the commands above; the primary is then stopped and one record moves a
viewer to the standby. It needs Docker Compose, FFmpeg and the Elixir toolchain
from [CONTRIBUTING](../CONTRIBUTING.md), and uses its own database and storage.

```sh
deploy/delivery-standby/drill/drill.sh run      # the whole rehearsal, with timings
deploy/delivery-standby/drill/drill.sh restore  # start the primary and switch back
deploy/delivery-standby/drill/drill.sh down     # remove everything
```

`up`, `sync`, `check`, `watch`, `outage` and `switch` run the steps one by one.
To watch a real player through the switch, resolve `drill.test` through the
drill's caching resolver at `10.77.0.3` (on Linux, a temporary
`nameserver 10.77.0.3` line in `/etc/resolv.conf` is enough) and open the player
page that `up` prints. It needs a browser that plays HLS in a video element,
such as Safari or a current Chrome.

Rehearse against the real standby as well: `check` with the edge URL exercises
the production hostnames and certificate without moving traffic.
