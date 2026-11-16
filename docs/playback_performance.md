# Playback performance

The **Playback** tab of the data page shows how reliably videos play and how
well delivery performs. It reads two sources and groups them the same way, so
a slow video or region can be compared with its cache and latency figures:

- **Viewer experience**, reported by the player: startup time, rebuffering,
  startup and playback failures, delivered bitrate and resolution.
- **Delivery**, reported by the CDN or edge server: cache hits and misses,
  origin requests and traffic, time to first byte and error rates. The player
  cannot observe these.

Both are optional. Without player events the viewer figures stay empty; without
delivery telemetry the tab says so and shows the viewer figures alone.

## Player events

Players send quality events to the existing `POST /v1/events` endpoint, next to
`play` and `pause`, with the same `session_id`, `embed_id` and `timestamp`. One
playback attempt is one session of one video.

| Event | Sent when | Fields |
| --- | --- | --- |
| `playback_request` | Playback is requested by a click or autoplay | |
| `playback_startup` | The first frame renders | `startup_ms` since the request |
| `playback_rebuffer` | A stall ends | `rebuffer_ms` it lasted |
| `playback_sample` | Every 10–30 seconds of playback, on a rendition switch and on pause | `playing_ms` since the previous sample, `bitrate` (bits per second), `width`, `height` |
| `playback_error` | Playback cannot continue | `error_code`, up to 64 characters |

```json
{"events": [{
  "name": "playback_startup",
  "session_id": "0b1f6a52-5d0c-4c0e-9d57-0d9f7a3c1e11",
  "embed_id": "ab1cdVIDEOHASH0",
  "timestamp": 1794863000000,
  "startup_ms": 812
}]}
```

An error before `playback_startup` counts as a startup failure, afterwards as a
playback failure. Rebuffering is the stalled share of stalled plus played time.
Durations are capped at ten minutes per event. The hosted player components do
not send these events yet; any player that follows this contract is measured.

### Viewer region

Core does not look up IP addresses. Set `MAVE_VIEWER_COUNTRY_HEADER` to the
request header in which your proxy or CDN passes the viewer's ISO 3166-1
country, for example `cf-ipcountry`. Only use a header your own edge sets or
overwrites. Without it, regions are reported as unknown.

## Delivery telemetry

Set `MAVE_CDN_TELEMETRY_TOKEN` (at least 16 characters) and let a log shipper
post media request logs:

```sh
curl -X POST https://mave.example.com/internal/cdn-telemetry \
  -H "Authorization: Bearer $MAVE_CDN_TELEMETRY_TOKEN" \
  -H "Content-Type: application/json" \
  -d '{"records": [{
        "timestamp": "2026-11-16T21:03:15Z",
        "url": "https://space-ab1cd.cdn.example.com/VIDEOHASH0/h264/720p/segment_4.m4s",
        "status": 200,
        "cache_status": "HIT",
        "bytes": 734112,
        "ttfb_ms": 23,
        "country": "NL",
        "pop": "AMS"
      }]}'
```

The response reports how many records were `accepted` and `dropped`. A request
holds at most 2000 records and 2 MB. The token is an operator credential:
records may refer to any space, so keep the endpoint away from tenants.

- `timestamp` is Unix milliseconds or ISO 8601, at most 31 days old.
- `url` identifies the video through the playback origin, public CDN or API
  media route. `host` and `path`, or `embed_id`, are accepted instead. Requests
  for anything else are dropped, so a whole log stream can be forwarded.
- `cache_status` accepts common provider values. `HIT`, `STALE`, `REVALIDATED`
  and `UPDATING` count as hits, `MISS` and `EXPIRED` as misses; `BYPASS` and
  `DYNAMIC` stay out of the cache hit ratio.
- `origin` (boolean) states whether the request reached the origin. It defaults
  to every request that was not a hit.
- `bytes`, `ttfb_ms`, `country` and `pop` are optional.

The error rate counts 4xx and 5xx responses. Strip query strings before
shipping when they carry playback tokens; Core ignores and never stores them.

## Diagnosis

The tab lists videos, devices, browsers and regions whose viewers are clearly
worse off than the space as a whole, largest first. For videos and regions it
adds what delivery shows for the same requests: a lower cache hit ratio, slower
edge responses or more errors. When delivery looks healthy, the cause is more
likely on the viewer's side. Thresholds and minimum sample sizes are documented
in [`Performance.findings/1`](../lib/mave_core/analytics/performance.ex).

## Storage

Rows land in the ClickHouse tables `playback_quality` and `cdn_requests` and
expire after 13 months. Request logs grow with every delivered segment; shorten
the retention with `ALTER TABLE cdn_requests MODIFY TTL` if that suits your
installation better. Viewing statistics and prepared analytics are unaffected.
