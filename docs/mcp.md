# Remote MCP

Mave Core exposes a remote [Model Context Protocol](https://modelcontextprotocol.io/specification/2025-11-25)
server at `/mcp`. The hosted URL is `https://api.mave.io/mcp` after the release
containing this feature has been deployed. Self-hosted installations use their
own API origin. There is no separate MCP process to run.

## Connect an assistant

Add the remote MCP URL to a client supporting **Streamable HTTP and browser
OAuth**. The client discovers Mave's authorization server, registers its callback,
and opens the existing Mave sign-in flow. Sign in, check the displayed app and
return address, choose a space, and approve the connection. The browser returns
to your client automatically.

The authorization screen shares its layout and components with Mave CLI login.
An app gets access to one selected space. `mave:read` is the default;
`mave:read mave:write` additionally permits creation, updates, imports and deletion.
Write access is explicitly shown on the consent screen. A client asking for
write access must request both scopes in its authorization URL.

Manage or disconnect apps at **Settings → Developer → Manage connected apps**
(or `/mcp/connections` on the dashboard). Disconnecting immediately invalidates
all access and refresh tokens for that connection. Removing the authorizing
user's access to the space also invalidates the connection.

This flow issues dedicated MCP credentials. It does not accept or expose API
keys, browser session cookies, CLI device tokens, or upload JWTs at `/mcp`.

## Tools

| Tool | Permission | Behavior |
| --- | --- | --- |
| `mave_get_connection` | Read | Selected space and granted scopes |
| `mave_list_videos` | Read | Pagination, collection and uploaded filters |
| `mave_get_video` | Read | Video metadata and available renditions |
| `mave_list_collections` | Read | Paginated collection list |
| `mave_create_video` | Write | Empty video or asynchronous public URL import |
| `mave_update_video` | Write | Rename or move; `collection: null` moves to root |
| `mave_delete_video` | Write | Delete after the user approves; requires `confirm: true` |
| `mave_create_collection` | Write | Named collection with optional parent |
| `mave_update_collection` | Write | Rename or move; `collection: null` moves to root |
| `mave_delete_collection` | Write | Delete after the user approves; requires `confirm: true` |

The command vocabulary and payloads follow [mave-cli](https://github.com/maveio/mave-cli).
Operations call Core's existing tenant-scoped contexts and serializers. API-side
space provisioning remains outside Core's MCP surface. Local file uploads,
Vimeo migration, webhook verification and source-file downloads remain CLI
operations. A remote server cannot read a file on the user's computer.

`mave_create_video` with `input_url` starts the existing media-processing flow.
Poll `mave_get_video` for renditions; accepted imports are not necessarily ready
for playback. Import URLs use Core's existing public-URL validation.

## Remote client example

Node.js 22 or later:

```sh
cd examples/mcp-client
npm ci
node client.mjs https://api.mave.io/mcp tools
node client.mjs https://api.mave.io/mcp call mave_list_videos '{"per_page":10}'
node client.mjs https://api.mave.io/mcp --write call mave_create_collection '{"name":"Product videos"}'
```

The example uses the official TypeScript SDK, opens a browser, verifies callback
state, and uses an ephemeral loopback callback. `--no-open` prints the link only.
Tokens remain in memory; each CLI invocation signs in again. For a longer-lived
application, import `connectMave` and reuse its returned SDK `Client`, then call
`client.close()`. The SDK can refresh tokens within that session. Persistent
clients should store tokens and issuer-bound registration in their OS credential
store and serialize refreshes for a connection.

```js
import { connectMave } from './examples/mcp-client/client.mjs';
const client = await connectMave({ url: 'https://api.mave.io/mcp' });
try {
  const result = await client.callTool({ name: 'mave_list_videos', arguments: {} });
  console.log(result.structuredContent);
} finally {
  await client.close();
}
```

## Deployment configuration

Run the normal Core database migration before serving this release. The migration
adds only MCP client, grant and token tables. It does not modify existing API keys.

| Variable | Default / purpose |
| --- | --- |
| `MAVE_MCP_RESOURCE_URL` | Canonical HTTPS URL ending in `/mcp`; defaults to `MAVE_API_HOST` with the dashboard scheme, otherwise `MAVE_DOMAIN` + `/mcp` |
| `MAVE_DOMAIN` | Existing dashboard origin; serves sign-in and `/oauth/mcp/authorize` |
| `MAVE_API_HOST` | Existing API hostname restriction |
| `MAVE_MANAGE_HOST` | Existing dashboard hostname restriction |
| `MAVE_MCP_ALLOWED_ORIGINS` | Extra comma-separated browser origins, e.g. a locally hosted MCP Inspector; API/dashboard origins are always allowed |

For a hosted deployment, set `MAVE_MCP_RESOURCE_URL=https://api.mave.io/mcp`.
Use HTTPS publicly. HTTP is accepted only for loopback resource overrides and
registered loopback callbacks. Origin checks apply to requests containing an
`Origin` header; server-to-server clients normally omit it. The endpoint retains
the existing maintenance gate, including staging restrictions.

Route these API-host paths through the existing reverse proxy:

- `/mcp`
- `/.well-known/oauth-protected-resource` and `/.well-known/oauth-protected-resource/mcp`
- `/.well-known/oauth-authorization-server`
- `/oauth/mcp/register`, `/oauth/mcp/token`, `/oauth/mcp/revoke`

The dashboard host serves `/oauth/mcp/authorize` and `/mcp/connections`. Do not
cache authenticated MCP or OAuth responses, or log request bodies, authorization
headers, codes, token responses or full authorization/callback URLs. Core marks
responses `no-store`, filters credential parameters, and disables route logging
for MCP, registration, exchange and revocation.

The existing Oban worker role prunes expired MCP records hourly in bounded
batches. Used refresh-token digests remain until their absolute expiration to
detect replay. Abandoned client registrations expire after 90 days without grants.

## Protocol and authorization

The transport implements MCP `2025-11-25`, `2025-06-18` and `2025-03-26` using
stateless POST requests with JSON responses. It negotiates `2025-11-25` for an
unknown initialization version. It does not advertise the 2026 per-request
envelope protocol, SSE subscriptions, server-initiated requests, tasks, prompts,
resources, session IDs or resumable streams. GET and DELETE return 405;
notifications receive 202. Send both `application/json` and `text/event-stream`
in `Accept`, and `application/json` in `Content-Type`.

OAuth implements authorization-code + S256 PKCE, dynamic public-client
registration, protected-resource metadata, authorization-server metadata,
resource indicators, refresh rotation and revocation. Client ID metadata
documents and confidential-client authentication are not advertised.

Authorization codes expire after five minutes and can be used once. Access
tokens expire after one hour; a connection's refresh lifetime is at most 30 days.
Reusing a consumed code or refresh token revokes the connection. Token requests
must include the exact `resource` and `client_id`; code exchange additionally
requires the original `redirect_uri` and PKCE verifier. Token hashes and grants
are stored in PostgreSQL, so replicas share authorization and revocation state.

Reference: [MCP authorization](https://modelcontextprotocol.io/specification/2025-11-25/basic/authorization)
and [Streamable HTTP](https://modelcontextprotocol.io/specification/2025-11-25/basic/transports).

## Development checks

With the disposable services from `CONTRIBUTING.md` running:

```sh
mix test test/mave_core/mcp test/mave_core_web/controllers/mcp_controller_test.exs test/mave_core_web/live/mcp_auth_live_test.exs test/mave_core_web/live/cli_auth_live_test.exs
npm ci --prefix examples/mcp-client
npm run check --prefix examples/mcp-client
mix test examples/mcp-client/interop_test.exs
```

The interoperability test starts a loopback HTTP server and exercises it with
the official SDK, using synthetic credentials. CI runs this in addition to the
full Core suite. No hosted service or real account is used by these tests.
