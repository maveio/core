# Webhook delivery

Webhook events are persisted before dispatch in `space_webhook_deliveries`.
This outbox records each destination's delivery state and retry history, so
application requests do not depend on an immediate successful HTTP callback.

| Fields | Purpose |
| --- | --- |
| `space_id`, `webhook_id` | Owning space and destination |
| `event_type`, `payload` | Event being delivered |
| `state` | `pending`, `processing`, `succeeded`, `failed` or `canceled` |
| `attempts`, `next_attempt_at` | Attempt history and retry scheduling |
| Response and error fields | Last recorded delivery outcome |

Video creation, upload, processing, readiness, deletion, archival and unarchival
can enqueue delivery events. Payloads and signatures are defined by the existing
webhook contract; changes must remain compatible with consumers.

For implementation and retry behavior, see
[`Spaces`](../lib/mave_core/spaces.ex),
[`Webhook`](../lib/mave_core/spaces/webhook.ex) and
[`WebhookDeliveryWorker`](../lib/mave_core/workers/webhook_delivery_worker.ex).
Persist events through these existing contexts rather than sending callbacks
from controllers or flow steps directly.
