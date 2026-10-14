# Password-protected playback

Branch: `feat/password-playback`

Videos can now require a viewer password while retaining direct object-storage
playback. Setting a password invokes the existing asynchronous private visibility
transition. Password sessions are issued only after the storage adapter confirms
protection, including its existing cache purge and origin verification.

The dashboard and video create/update API share the same validation and access
context. The API accepts a write-only `password`; missing leaves it unchanged,
JSON `null` removes it while retaining private visibility. Responses expose only
`password_protected`. Public discovery and token endpoints exist under both
`/v1/playback/:id` and `/api/v1/playback/:id`.

Passwords are salted Argon2id hashes. Four-hour Phoenix tokens use a separate
purpose, embed scope and revocation revision. Rotation and removal revoke old
sessions; previously signed object-storage URLs keep their original expiry.
The existing API JWT and dashboard authorities are unchanged. Password attempts
use the existing per-node limiter with both embed/IP and aggregate IP limits.

## Migration and dependencies

- Adds nullable `embeds.password_hash` and non-null `password_revision` (default
  zero). Existing embeds remain unchanged and unprotected by password.
- Adds `argon2_elixir` and its `comeonin` dependency; the native module compiled
  successfully with the standard local toolchain.
- Requires the accompanying Components password player for automatic prompts.
  Static `player.html` remains public; its component uses the same password flow.
- Existing storage adapter callbacks and signed-media URL contracts are unchanged.
  Self-hosting still requires an adapter that genuinely protects storage prefixes.

## Validation

Run in isolated PostgreSQL, ClickHouse and MinIO services, with a clean test
environment and `TMPDIR=/private/tmp` on macOS:

- Targeted playback, video API and dashboard tests: **143 passed**.
- Complete `mix test`, including integration tests: **1208 passed**.
- Existing downstream playback adapter, bucket synchronization, configuration
  and host-routing tests: **18 passed**, using separate disposable databases.
- `mix credo --strict`, `mix security`, `mix security.enforce`, `mix precommit`
  and `git diff --check`: passed. `mix security` retains existing low-severity
  repository findings; no new findings were introduced.

The real MinIO test covers protection of existing manifest, HLS, MP4, segment
and subtitle objects; public static player access; authorized redirects and
signed storage reads; future replacement objects; domain/CORS synchronization;
revocation; and already-issued URL expiry behavior. Controller and dashboard
regressions cover pending/failed storage synchronization, password rotation and
removal, scope and token purpose, expired tokens, API write permissions, minimal
responses, redaction, rate limits and unavailable playback adapters.
