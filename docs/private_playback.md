# Private playback

Videos are public by default. A configured playback adapter enables the dashboard
access menu and the API `visibility` field (`"public"` or `"private"`). The response
reports the last visibility confirmed by storage synchronization. Changing access
runs in the background: `PUT /api/v1/videos/:id` returns `202 Accepted` while the
change is pending. Poll `GET /api/v1/videos/:id` until it returns `200 OK` with the
requested visibility; it also returns `202` while pending, including on retries.
Creation, ordinary updates and already confirmed visibility retain `200 OK`.

## Using tokens

Create or update a video with `visibility: "private"` using a write-capable API key.
Sign playback JWTs on your server with a read-only space API key, using the complete
key copied from the dashboard. `sub` scopes access to a space, collection or video.
Use `exp` to set an expiry in Unix seconds; `iat` and `aud` are not required.
Without `exp`, the JWT remains valid until its signing key is revoked.

```html
<mave-player embed="YOUR_EMBED_ID" token="YOUR_PLAYBACK_TOKEN"></mave-player>
```

For a custom player, use
`/api/v1/playback/media/{public_embed_id}/playlist.m3u8?token=YOUR_PLAYBACK_TOKEN`,
or the optional media hostname below. Other media files use the same base path.
Media routes also accept `Authorization: Bearer YOUR_PLAYBACK_TOKEN`.
Playlists, captions, storyboards and images use the same authorization. Child
playlists retain the JWT; media files use temporary signed storage URLs, valid
for at most 24 hours and no longer than the token's remaining lifetime.

Authorize viewers before issuing tokens. Keep API keys on the server and exclude
tokens and signed URLs from logs. Issued storage URLs remain usable until expiry.

Dashboard previews receive an automatic 24-hour token and refresh it before expiry.
Overview thumbnails also use signed URLs, with five minutes of private browser
caching. Private iframe snippets are omitted because they cannot pass a token.

## Storage adapters

Configure `:mave_core, :playback_adapter` with a module implementing
`MaveCore.Playback.Adapter`. It must protect existing and future objects, purge
cached public copies and verify access before reporting success. Domain/CORS
synchronization must preserve these policies. The optional `token_endpoint/0`
callback selects the Phoenix endpoint used to sign dashboard tokens.

Development includes a MinIO adapter without a CDN. The standalone development
Compose stack exposes its API on loopback port 9000 (`MAVE_MINIO_API_PORT` can
change this). For other local setups, set `MAVE_PLAYBACK_STORAGE_ENDPOINT` to the
browser-reachable MinIO endpoint; signatures must use that exact endpoint.

## Optional media hostname

Set `MAVE_PLAYBACK_ORIGIN=https://signed.example.com` to serve private media at:

```text
https://space-{space_hash}.signed.example.com/{embed_hash}/playlist.m3u8?token=JWT
```

Point wildcard DNS at the application and use TLS for `*.signed.example.com`.
This host serves only media GET/HEAD and CORS preflight requests. The API’s existing
`poster_image` field and component `cdn.playback_endpoint` settings use it automatically. Leaving it unset
uses `/api/v1/playback/media/{public_embed_id}/...`; those routes remain available
when a media hostname is configured. Do not enable shared caching on these routes.

## Password-protected videos

Create or update a video using the write-only `password` property. A non-empty
UTF-8 string (at most 1024 bytes) sets or rotates the password; an omitted field
preserves it and JSON `null` removes it. Responses include only the boolean
`password_protected`. Passwords use salted Argon2id hashes and are excluded from
request logging; hashes/revisions are redacted from inspection and dashboard
assigns. Removal revokes password sessions and leaves the video private. Remove
the password before a separate request to publish the video.

Setting a password uses the same space eligibility and storage adapter as token
playback. A pending transition returns `202`; password playback is unavailable
until storage protection and cache purging have succeeded. Protected prefix
policy applies to future uploads and video replacements as well as existing
media. The public `player.html` remains accessible and renders the password form.

After the public manifest fails to load, `mave-player` (and `mave-audio`) calls
`GET /v1/playback/:embed_id/access`, which returns only
`{"password_protected": true|false}`. Unknown or deleted embeds return `404`.
It then sends `POST /v1/playback/:embed_id/password-token` with a JSON `password`.
A successful response contains `token` and `expires_at` (Unix seconds). Both
routes also exist under `/api/v1`, allow CORS and return `private, no-store`.

Errors contain a single `error` code: `invalid_password` (`401`, including a
missing or unprotected video), `protection_pending` (`409`),
`playback_unavailable` (`503`) or `rate_limited` (`429`, with `Retry-After`).
The player retains the token in memory and sends it through the existing private
media routes. Explicit caller-provided playback tokens take precedence.

Password tokens last four hours and have a separate signing purpose from
internal dashboard tokens. They are scoped to one embed and revision; every
media authorization rechecks the current revision. Rotation and removal revoke
old password sessions. Existing API JWTs and dashboard tokens keep their existing
authority. Media bytes still come directly from object storage using signed
URLs; those URLs keep the existing maximum 24-hour limit, capped by the token's
remaining lifetime (therefore at most four hours for password sessions). An
already issued storage URL remains usable until it expires, even after rotation.

The existing per-node Hammer limiter permits five attempts per minute per
embed/IP and thirty per IP across videos. Configure it with
`:mave_core, MaveCoreWeb.Plugs.PasswordPlaybackRateLimit` using `interval_ms`,
`per_embed_ip` and `per_ip`. All attempts count, including successful ones. IPs
are hashed in ephemeral limiter keys and are not logged or sent to analytics.
Proxy handling reuses `MaveCoreWeb.Plugs.EventIngestRateLimit`'s
`trusted_proxy_cidrs`; untrusted forwarded headers are ignored. Deployments with
multiple nodes should enforce aggregate rate limits at their ingress when needed.
