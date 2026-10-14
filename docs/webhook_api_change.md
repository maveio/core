# Webhook registration API

Branch: `feat/webhook-api`. Base: `origin/main`. No feature dependencies.

Automation clients can register a chosen destination, event set and signing secret
through authenticated `/v1/webhooks` and `/api/v1/webhooks` endpoints. Read-only
keys can list registrations; writes require the existing read/write permission.
The response omits secrets and preserves Core's legacy short UUID identifiers.
The complete HTTP and signature contract is in
[Webhook delivery outbox](webhook_delivery_outbox.md#registration-api).

Registration retries are serialized per space and reuse the same ID, including
when callers send events in a different order. Separate database connections are
covered by a concurrency test. Removing a subscription also cancels queued
deliveries and retains the audit log. A request already in flight may finish, but
its failure cannot reintroduce a retry after removal.

Migration `20261014143703_add_webhook_deletion_state` adds nullable `deleted_at` to
`space_webhooks`; existing rows remain active. Dashboard deletion adopts the same
tombstone semantics. No existing event name, webhook payload, signing algorithm,
or delivery endpoint changes.

## Validation

All database checks used disposable PostgreSQL on port 55439, ClickHouse on 8123,
and MinIO on 19010, with synthetic test fixtures. macOS required
`TMPDIR=/private/tmp` because the media filesystem guard rejects the `/tmp`
symlink when the environment is cleared.

- Targeted API, registration, existing delivery and Spaces tests: **42 passed**.
- Full `mix test`, including media integrations: **1209/1210 passed**; the sole
  failure asserted the previous hard-delete behavior in dashboard settings.
- After updating that assertion to check the tombstone and context invisibility,
  dashboard settings plus all new webhook tests: **35 passed**. This includes
  independent-connection registration concurrency and worker crash recovery.
- `mix precommit`: passed (format, warnings-as-errors compilation, xref audit).
- `mix credo --strict`: passed.
- `mix security`: passed; existing low-confidence Sobelow findings remain.
- `mix security.enforce`: passed.
- `git diff --check`: passed.

No pushes, pull requests, deployments, or production migrations were performed.
