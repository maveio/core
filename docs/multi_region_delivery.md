# Multi-region delivery

A space stores and serves its media from one region by default. Multi-region
delivery is an optional addition: the space keeps that primary region and copies
its public media to one or more replica regions. When the region that serves
viewers has problems, another region takes over.

Regions are [storage profiles](../lib/mave_core/storage_profiles.ex). The controls
appear under **Settings → Region** once more than one profile is configured.

## Configure regions

A standalone installation adds profiles with environment variables. This example
adds `ams` next to the default profile:

```sh
MAVE_STORAGE_REGIONS=ams
MAVE_STORAGE_REGION_AMS_ENDPOINT=https://s3.ams.example.com
MAVE_STORAGE_REGION_AMS_ACCESS_KEY=...
MAVE_STORAGE_REGION_AMS_SECRET_KEY=...
```

Per region, replacing `AMS` with the upper-case region id (`DEFAULT` for the
default profile):

| Variable | Purpose |
| --- | --- |
| `MAVE_STORAGE_REGION_AMS_REGION` | Signing region, `us-east-1` by default |
| `MAVE_STORAGE_REGION_AMS_BUCKET_PREFIX` | Bucket prefix, `space-` by default |
| `MAVE_STORAGE_REGION_AMS_PUBLIC_BASE_URL` | Where browsers reach this region's buckets |
| `MAVE_STORAGE_REGION_AMS_NAME`, `_PROVIDER`, `_LOCATION` | Labels on the region card |

Applications that embed Core configure `:storage_providers` directly; a profile
may carry `public_base_url` there. A profile that resolves to the primary's own
bucket is not offered as a replica.

Replication and health checks run on the `multi_region` Oban queue. Core's
default configuration includes it; add it when you define your own queues.

## What a replica holds

The primary region is the only place Core writes to. Replication compares the
replica bucket with the primary bucket, copies missing or changed objects and
deletes objects that left the primary. It runs shortly after a video changes and
as a full comparison every 15 minutes, so a run can always be repeated safely.

Only media of publicly playable videos is copied. Deleting a video or making it
[private](private_playback.md) removes its copy from every replica, and a video
is not reported as private before the replicas confirmed that. Private videos
are therefore served from the primary region only. A replica also receives the
space's CORS and access configuration.

Removing a region deletes its copy. The primary is never modified.

## Health and failover

Every minute Core checks each region of every multi-region space through its
storage API. A failing check is confirmed with two more attempts five seconds
apart before the region counts as unavailable. A region that was unavailable
has to pass two checks in a row before it counts as healthy again.

With automatic failover, which is the default:

- when the serving region is unavailable, delivery moves to the first healthy
  region that holds a complete copy;
- when the primary has recovered, delivery returns to it.

With automatic failover switched off, the serving region only changes when
someone chooses it in the dashboard. A replica can be chosen once its first full
copy has completed.

Uploads and processing need the primary region. They fail while it is down and
work again once it is back; failover covers viewing.

## Serving viewers from the right region

Core offers two ways to make viewers follow the serving region. Use one.

**Delivery route.** `GET /delivery/{bucket}/{path}` redirects to the same object
in the region that currently serves the space. Point the public media base URL
at it and every existing embed, player and API URL follows failover:

```sh
MAVE_PUBLIC_CDN_BASE_URL=https://video.example.com/delivery
MAVE_PUBLIC_CDN_MODE=path
MAVE_STORAGE_REGION_DEFAULT_PUBLIC_BASE_URL=https://video.example.com/storage
MAVE_STORAGE_REGION_AMS_PUBLIC_BASE_URL=https://ams.video.example.com/storage
```

The redirect is cached for 30 seconds. Playlists and manifests resolve their
relative URLs against the redirect target, so media bytes do not pass through
Core. A viewer who is mid-playback when a region fails has to reload. A base
URL may contain `{bucket}` for CDNs that serve each space from its own hostname.
Without a public base URL, a region is reached at its storage endpoint.

**Your own CDN.** A CDN or load balancer that selects its origin itself can keep
serving one hostname. Configure `:mave_core, :multi_region_delivery_router` with
a module implementing `delivery_region_changed(space, from, to, reason)`, or a
four-arity function, and switch the origin pool or DNS record there.

## Host hooks

| Configuration | Purpose |
| --- | --- |
| `:usage_limits_backend` with `can_use_multi_region?/1` | Decide which spaces may add regions |
| `:multi_region_health_check` | Replace the storage check, for example to also test a CDN; `fun.(region, bucket)` or a module with `check_region/2` |
| `:multi_region_delivery_router` | Follow delivery changes, see above |
| `:multi_region` | Thresholds and intervals; see [`MaveCore.MultiRegion`](../lib/mave_core/multi_region.ex) |
