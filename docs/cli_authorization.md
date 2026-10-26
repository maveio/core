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

Approval is restricted to the signed-in user's spaces. Exchanging an approved
device code creates a read/write space key. Client metadata is display-only and
cannot change the selected space, authorization or key access level.

Settings → Developer displays CLI keys in the existing **API Keys** table. The
key description defaults to **Mave CLI**, with the supplied device name (or
**Device name unavailable**) and optional CLI version shown underneath. The usual
reveal, copy, edit, access-level and delete actions apply. No device name is
inferred from the browser, IP address or existing descriptions. Deleting the key
via the existing space-scoped context immediately invalidates its credentials.

Older keys without client metadata remain ordinary API keys. Reconnect with
`mave login` to attach device information to a new key, then revoke the old key
if it is no longer used.
