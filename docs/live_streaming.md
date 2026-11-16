# Live streaming

A space can broadcast live from OBS or any other encoder that publishes RTMP.
Core repackages the stream as HLS without re-encoding, stores the segments in
the space's bucket and serves a playlist that players follow. When the
broadcast ends, the same address plays the recording.

This is a first version. [Limits](#limits-of-this-version) lists what it leaves out.

## Enable it

Live streaming is off by default. An installation turns it on, and a host can
limit it to selected spaces.

| Variable | Default | Purpose |
| --- | --- | --- |
| `MAVE_LIVE_ENABLED` | `false` | Accept RTMP connections and show live streaming to spaces |
| `MAVE_LIVE_RTMP_PORT` | `1935` | TCP port the RTMP listener binds |
| `MAVE_LIVE_RTMP_URL` | derived from `MAVE_DOMAIN` | Server address shown to users, for example `rtmp://live.example.com/live` |
| `MAVE_LIVE_RECONNECT_SECONDS` | `60` | How long a broadcast waits for its encoder to return |

Encoders must reach the RTMP port directly; an HTTP reverse proxy does not
forward it. In the self-hosted Compose stack, publish the port on the `core`
service and set the variables in its environment:

```yaml
services:
  core:
    ports:
      - "1935:1935"
```

RTMP is not encrypted. For RTMPS, terminate TLS in a TCP proxy in front of the
port and set `MAVE_LIVE_RTMP_URL` to the `rtmps://` address.

Hosts that offer live streaming on specific subscriptions implement the
optional `can_use_live_streaming?/1` callback of `MaveCore.UsageLimits`. A
space that is not allowed has no Live page, cannot publish, and its playback
addresses answer 404.

Run one Core node with live streaming enabled. Other nodes serve the dashboard,
the API and playback, but an encoder that reconnects must reach the same node.

## Go live from OBS

1. Open **Live** in the dashboard and create a stream.
2. In OBS, open **Settings → Stream**, choose **Custom**, and paste the server
   and the stream key.
3. Under **Output**, use H.264 video and AAC audio with a keyframe interval of
   2 seconds.
4. Start streaming. The stream page shows the broadcast within a few seconds.

The stream key is a secret. Replacing it stops other encoders from starting a
broadcast; an encoder that is connected keeps publishing.

A stream is a reusable channel with a stable key and playback address:

| Status | Meaning |
| --- | --- |
| `idle` | Never broadcast |
| `live` | An encoder is publishing |
| `disconnected` | The encoder is gone; the broadcast resumes if it returns within the reconnect window |
| `ended` | The broadcast is over and its recording plays |

The next broadcast replaces the recording of the previous one.

## Playback

Each stream has three public addresses, shown on its page and returned by the API:

- **Player**: `/api/v1/live/{id}/embed`, a page for an `<iframe>`. It waits
  while the stream is offline, plays the broadcast, and plays the recording afterwards.
- **HLS playlist**: `/api/v1/live/{id}/index.m3u8`, for your own player.
- **Status**: `/api/v1/live/{id}`, JSON with `status`, `broadcast`, `started_at`,
  `ended_at` and `playable`.

Anyone who has an address can watch. Segments are public media of the space,
served from the same origin as its videos, so the space's allowed domains and
hotlink protection apply to them. A player on your own site must be on an
allowed domain.

Viewers are about 8 to 12 seconds behind the encoder.

## API

All routes use the space's API key. Changes need a key that is not read-only.

| Request | Result |
| --- | --- |
| `GET /api/v1/live_streams` | List streams |
| `POST /api/v1/live_streams` | Create a stream; optional `name` |
| `GET /api/v1/live_streams/{id}` | Fetch a stream |
| `PUT /api/v1/live_streams/{id}` | Rename a stream |
| `POST /api/v1/live_streams/{id}/reset_key` | Replace the stream key |
| `DELETE /api/v1/live_streams/{id}` | Delete the stream and its recording |

```json
{
  "object": "live_stream",
  "id": "s8ckqaij9nhrj9b",
  "name": "Town hall",
  "status": "idle",
  "created": 1794865884,
  "started_at": null,
  "ended_at": null,
  "encoder": null,
  "error": null,
  "ingest": {"url": "rtmp://live.example.com/live", "stream_key": "live_…"},
  "playback": {
    "hls": "https://example.com/api/v1/live/s8ckqaij9nhrj9b/index.m3u8",
    "player": "https://example.com/api/v1/live/s8ckqaij9nhrj9b/embed",
    "embed": "<iframe src=\"…\"></iframe>"
  }
}
```

While a broadcast runs, `encoder` holds what the encoder reports: resolution,
frame rate, codecs and bitrates. `error` explains a refused stream, for example
video that is not H.264.

## How it works

- `MaveCore.LiveStreams.RTMP.Connection` accepts the encoder, and the stream
  key selects the stream.
- `MaveCore.LiveStreams.Session` pipes the media as FLV into FFmpeg, which cuts
  MPEG-TS segments at keyframes without re-encoding. FFmpeg reads standard
  input only, so it runs in the [media sandbox](media_security.md) without
  network access.
- Each finished segment is uploaded to `live/{stream}/{broadcast}/{n}.ts` in
  the space's bucket and recorded in `live_stream_segments`. A segment is
  listed only after it is stored.
- The playlist is rendered from those rows: the last six segments while live,
  all of them with `#EXT-X-ENDLIST` once ended. A reconnect continues the
  playlist after `#EXT-X-DISCONTINUITY`.

FFmpeg's CPU budget (`MAVE_MEDIA_MAX_CPU_SECONDS`) counts for a whole
connection. Repackaging uses little CPU, so the default covers days of streaming.

## Limits of this version

- One quality: viewers get the encoder's stream as sent. No transcoding or
  adaptive bitrate ladder.
- H.264 video with AAC or MP3 audio over RTMP. HEVC, AV1, SRT and WHIP are refused or absent.
- Playback is public by address. Private playback tokens do not apply.
- One recording per stream, replaced by the next broadcast. A recording is not
  converted into a regular video with renditions, captions or analytics.
- Streams are not placed in collections and do not use `<mave-player>`.
- No webhooks for stream events.
- A single ingest node.
