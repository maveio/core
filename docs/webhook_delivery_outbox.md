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
