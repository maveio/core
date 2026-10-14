import assert from 'node:assert/strict';
import { auth } from '@modelcontextprotocol/sdk/client/auth.js';
import { Client } from '@modelcontextprotocol/sdk/client/index.js';
import { StreamableHTTPClientTransport } from '@modelcontextprotocol/sdk/client/streamableHttp.js';

const url = new URL(process.env.MAVE_MCP_TEST_URL);
assert.equal(url.hostname, '127.0.0.1', 'This test must only contact its disposable local server.');
let registration, verifier, authorizationUrl;
const redirectUrl = 'http://127.0.0.1:45678/callback';
const provider = {
  redirectUrl,
  clientMetadata: { client_name: 'SDK OAuth interoperability', redirect_uris: [redirectUrl],
    grant_types: ['authorization_code', 'refresh_token'], response_types: ['code'],
    token_endpoint_auth_method: 'none', scope: 'mave:read' },
  state: () => 'interop-state',
  clientInformation: () => registration,
  saveClientInformation: value => { registration = value; },
  tokens: () => undefined,
  saveTokens: () => {},
  saveCodeVerifier: value => { verifier = value; },
  codeVerifier: () => verifier,
  redirectToAuthorization: value => { authorizationUrl = value; },
};
assert.equal(await auth(provider, { serverUrl: url, scope: 'mave:read' }), 'REDIRECT');
assert(registration.client_id);
assert.equal(authorizationUrl.searchParams.get('resource'), url.href);
assert.equal(authorizationUrl.searchParams.get('code_challenge_method'), 'S256');
assert.equal(authorizationUrl.searchParams.get('state'), 'interop-state');
assert.equal(authorizationUrl.searchParams.get('redirect_uri'), redirectUrl);
assert(verifier.length >= 43);
const client = new Client({ name: 'mave-interop-test', version: '1.0.0' });
try {
  await client.connect(new StreamableHTTPClientTransport(url, {
    requestInit: { headers: { Authorization: `Bearer ${process.env.MAVE_MCP_TEST_TOKEN}` } },
  }));
  const { tools } = await client.listTools();
  assert(tools.some(tool => tool.name === 'mave_list_videos'));
  assert(!tools.some(tool => tool.name === 'mave_delete_video'));
  const result = await client.callTool({ name: 'mave_list_videos', arguments: { per_page: 10 } });
  assert.equal(result.isError, false);
  assert.deepEqual(result.structuredContent.data, []);
  await client.ping();
  console.log('MCP SDK interoperability passed');
} finally {
  await client.close();
}
