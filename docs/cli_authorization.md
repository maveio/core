# CLI browser authorization

`POST /api/v1/cli/authorizations` (also `/v1/cli/authorizations`) accepts an empty
JSON object for compatibility. These optional top-level strings are retained:

| Field | Maximum length | Meaning |
| --- | --- | --- |
| `client` | 64 characters | Client identifier, normally `mave-cli` |
| `version` | 64 characters | CLI version, e.g. `0.1.0` |
| `device_name` | 160 characters | Computer name supplied by the CLI |

Normalization removes Unicode control/format characters (`Cc`/`Cf`) and trims
surrounding whitespace. Length limits apply to the normalized Unicode strings.
Missing, blank, non-string and overlong values are omitted without rejecting the
login request. Unknown fields are ignored. Metadata is display-only: it grants no
permissions and cannot select a space or change access level. The browser labels
the device name as client-supplied.

The response, expiration, polling interval and token exchange contract are
unchanged. Approval is restricted to the signed-in user's spaces. Only the
one-time exchange of an approved device code creates a read/write space key.

The authorization stores `client_metadata`. Exchange copies it into the key's
`cli_metadata`, including `{}` when no metadata was supplied. A non-null
`cli_metadata` is the explicit provenance marker for a CLI connection; ordinary
key creation/editing cannot set this field. `purpose` remains reserved for
internal keys. Authentication, access levels and space isolation still use the
existing key mechanisms.

Settings → Developer displays CLI keys in the existing **API Keys** table. The
key description defaults to **Mave CLI**, with the supplied device name (or
**Device name unavailable**) and optional CLI version shown underneath. The usual
reveal, copy, edit, access-level and delete actions apply. No device name is
inferred from the browser, IP address or existing descriptions. Deleting the key
via the existing space-scoped context immediately invalidates its credentials.

Before this metadata was added, the server ignored all client fields and created
keys with only the editable description `Mave CLI`. Those records cannot be
reliably distinguished from ordinary keys with the same name, so the migration
does not reclassify them. They remain manageable under API Keys with their stored
description. Reconnect with `mave login` to retain client metadata on a new key,
then delete the old key if it is no longer used.

CLI 0.1.0 already sends `client` and `version`; it remains compatible without
changes. To display a computer name, the CLI must additionally send optional
`device_name` in its initial authorization request. If no meaningful name is
available, omit the field. No exchange-endpoint changes are needed.
