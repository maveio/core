# Webhook Delivery Outbox (replacing `spaces_events`)

Last updated: 2026-02-16

## Why replace `spaces_events`

Legacy `spaces_events` mixed two concerns:

1. Event/audit record.
2. Webhook dispatch trigger source.

For core v1, we split this into a delivery-first model so webhook reliability is explicit and queryable.

## New model

Core table: `space_webhook_deliveries`

- `event_type` + `payload`: canonical webhook payload data.
- `state`: `pending | processing | succeeded | failed | canceled`.
- `attempts`, `next_attempt_at`: retry scheduling control.
- response snapshot fields (`response_code`, `response_headers`, `response_body`, `error`).
- `space_id` + `webhook_id`: ownership and destination.

This table acts as an outbox and delivery audit log.

## Behavioral equivalence target

- Existing webhook signatures and payload structure stay compatible with legacy behavior.
- Core still emits webhook jobs for the same event moments (video created/uploaded/deleted/processing/ready/archived/unarchived).
- Failed dispatches become observable from persisted delivery state instead of best-effort logging only.

## Migration impact

- Do not import `spaces_events` rows directly unless needed for historical audit.
- During import, create `space_webhook_deliveries` only for rows that still require replay (normally none for one-time cutover).
- If event history API is needed later, expose from this table or add a thin `space_events` audit table as a read model.

## Registration API

Automation integrations may manage their own subscriptions using the existing space
API-key authentication: Basic credentials or `Bearer base64(key:secret)`. This Bearer
credential is not a JWT. Both `/v1` on the API host and the legacy `/api/v1` prefix
provide the following endpoints:

| Method | Path | Result |
| --- | --- | --- |
| GET | `/v1/webhooks` | `200`, `{ "data": [...] }` for the authenticated space |
| POST | `/v1/webhooks` | `201` for a new registration, `200` for an identical registration |
| DELETE | `/v1/webhooks/:id` | `204`, including an already removed, missing, or foreign ID |

POST and DELETE require a read/write key; a read-only key receives `403`. Missing
or invalid credentials receive `401`. Registration validation failures receive
`422` with an `errors` map keyed by field name.

POST accepts the following JSON fields:

```json
{
  "url": "https://automation.example.com/mave-events",
  "enabled_events": ["video_ready", "video_uploaded"],
  "secret": "<client-generated random signing secret>"
}
```

Generate and persist a high-entropy signing secret before registration; Core does
not return it. The secret is required and limited to 255 characters. The destination
must be HTTPS and resolve only to public addresses. The delivery path checks DNS
again and pins the connection to a validated address; it does not follow redirects.

Supported registration event names are `video_created`, `video_uploaded`,
`video_deleted`, `video_archived`, `video_unarchived`, `video_processing`, and
`video_ready`. At least one is required. Event order and duplicates do not affect
registration identity. The combination of space, trimmed URL, event set, and secret
is registered atomically, so retries return the same registration ID. A different
secret produces a separate registration. Unknown ownership or enabled fields in
the request cannot change the owning space or initial enabled state.

Each returned registration contains only `id` (legacy short UUID), `url`, `enabled_events`,
`enabled`, and `created_at` (UTC ISO 8601). POST wraps that object in `data`; GET
returns all active registrations in `data`. Registration credentials and secrets
are not serialized, inspected, or written to request/parameter logs.

Deletion disables and tombstones the registration, hides it from registration
lookups/lists, marks pending deliveries canceled, and cancels queued retry jobs.
The outbox audit history remains available in the dashboard. A removed registration
cannot be re-enabled through a stale dashboard record. Registering it again creates
a new ID. An HTTP request already claimed for delivery can finish; a failed in-flight
request cannot schedule a new attempt after removal. The `deleted_at` migration is
additive and applies these same semantics to dashboard deletion.

## Verifying delivered events

The wire event type uses dots, for example `video.ready`, while registration uses
`video_ready`. The JSON envelope remains `{id, type, data, object, created}` with
`object` equal to `event`, `created` in Unix seconds, and the public video response
inside `data`.

Read `Mave-Signature: t=<unix-seconds>,v1=<lowercase-hex-signature>` and reject missing,
malformed or stale timestamps (a five-minute tolerance is suitable for integrations).
Calculate **HMAC-SHA256 with the UTF-8 key `timestamp + "." + signing_secret` and
the original raw request body as the message**. Compare the 32-byte result with
the decoded `v1` using a constant-time comparison. This is Core's existing signing
algorithm; it differs from schemes that prepend the timestamp to the message.
Do not parse and reserialize JSON before verification. Retries are signed with a
fresh delivery timestamp; use the event ID for downstream deduplication.
