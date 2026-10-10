# Private playback

Videos are public by default. A configured playback adapter enables the dashboard
access menu and the API `visibility` field. Changing access runs in the background;
`visibility_status` remains pending until storage synchronization succeeds.

## Using tokens

Create or update a video with `visibility: "private"` using a write-capable API key.
Sign playback JWTs on your server with a read-only space API key, using the complete
key copied from the dashboard. `sub` scopes access to a space, collection or video.
Use `exp` to set an expiry in Unix seconds; `iat` and `aud` are not required.
Without `exp`, the JWT remains valid until its signing key is revoked.

```html
<mave-player embed="YOUR_EMBED_ID" token="YOUR_PLAYBACK_TOKEN"></mave-player>
```

For a custom player, append `?token=YOUR_PLAYBACK_TOKEN` to the API's returned
`sources` URL. Media routes also accept `Authorization: Bearer YOUR_PLAYBACK_TOKEN`.
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
This host serves only media GET/HEAD and CORS preflight requests. API sources and
component `cdn.playback_endpoint` settings use it automatically. Leaving it unset
uses `/api/v1/playback/media/{public_embed_id}/...`; those routes remain available
when a media hostname is configured. Do not enable shared caching on these routes.
