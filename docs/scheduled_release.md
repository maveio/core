# Scheduled releases

A scheduled release publishes a video at a fixed time. Until then, embeds show a
countdown and the media itself is unavailable: the release builds on
[private playback](private_playback.md), so storage denies unsigned reads of every
object under the video prefix. A configured playback adapter is therefore required.

## Lifecycle

1. **Schedule.** The dashboard (video actions → schedule release) or the API sets
   `release_at`. Only public videos can be scheduled. Core requests private
   storage and queues a `ReleaseWorker` job for `release_at`.
2. **Pending.** Public players load a countdown manifest without media references
   (see below). Customer playback JWTs are rejected for media, images and
   thumbnails. Dashboard previews keep working with their session token. The
   access toggle is locked; change the time or publish instead.
3. **Release.** At `release_at` the worker requests public storage. A cron sweep
   runs every minute, so releases still happen after downtime or a lost job.
4. **Completed.** When storage confirms public access, `release_at` is cleared and
   players receive the normal manifest. Until then the countdown manifest keeps
   being served, so players wait instead of failing.

Publishing early sets the release time to now and follows the same path.

## API

`PUT /api/v1/videos/:id` and `POST /api/v1/videos` accept `release_at` as Unix
seconds or as an ISO 8601 timestamp with a time zone. On updates,
`"release_at": null` publishes a scheduled video immediately and is a no-op for
other videos. Video responses include `release_at` (Unix seconds) while a release
is pending, otherwise `null`. While pending, `visibility` reports `"private"`, the
confirmed storage state. A response can be sent back as an update: an unchanged
`release_at` or `visibility` is ignored, but a release cannot change visibility.
Like visibility changes, updates return `202 Accepted` while storage converges.
Requests are validated before any change is applied.

## What is protected

Scheduling protects everything under the video prefix from that moment on,
including later uploads and replacements, and Core rejects playback tokens until
the release. It cannot recall what viewers already loaded while the video was
public, such as thumbnails or frames cached by browsers and image CDNs. For an
unseen premiere, schedule before sharing the embed, ideally before uploading
(the video page and `POST /api/v1/videos` both allow this).

If storage synchronization fails, the release stays pending (viewers keep
waiting) and the per-minute sweep queues it again until it succeeds.

## Player contract

Players fetch `manifest.json` from the space CDN as usual. Storage denies it while
the release is pending, so `@maveio/components` falls back to
`GET /api/v1/{public_embed_id}`, which returns the countdown manifest with a five
second shared cache. With a playback token, `/playback/media/{id}/manifest.json`
returns the same manifest.

The countdown manifest has `video.status: "scheduled"`, `release_at` and
`server_time` (Unix seconds, for clock skew), the player settings, and empty
`renditions`, `subtitles` and `audio_tracks`. Generated thumbnails are frames of
the video and are omitted. An uploaded custom poster is stored outside the video
prefix and is included, so it can be shown behind the countdown.

When the countdown ends, players refetch the manifest with jitter and keep
polling with backoff (up to a minute) until the release completes, then start
playback. Waiting players also recheck every five minutes, so an earlier or
later release time reaches open pages.
