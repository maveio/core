import { createServer } from 'node:http';
import { randomBytes, timingSafeEqual } from 'node:crypto';
import { once } from 'node:events';
import { spawn } from 'node:child_process';
import { pathToFileURL } from 'node:url';
import { Client } from '@modelcontextprotocol/sdk/client/index.js';
import { StreamableHTTPClientTransport } from '@modelcontextprotocol/sdk/client/streamableHttp.js';
import { UnauthorizedError } from '@modelcontextprotocol/sdk/client/auth.js';

/** Connect with browser OAuth. Credentials remain in memory for this session. */
export async function connectMave({ url = 'https://api.mave.io/mcp', write = false, openBrowser = true } = {}) {
  const endpoint = new URL(url);
  if (endpoint.protocol !== 'https:' && !(endpoint.protocol === 'http:' && ['localhost', '127.0.0.1', '[::1]'].includes(endpoint.hostname))) {
    throw new Error('Use HTTPS, or loopback HTTP for local development.');
  }
  if (endpoint.username || endpoint.password || endpoint.search || endpoint.hash) {
    throw new Error('The MCP URL must not include credentials, query parameters, or a fragment.');
  }
  const state = randomBytes(32).toString('base64url');
  const callback = Promise.withResolvers();
  // A timeout can occur while discovery is still running; preserve the rejection
  // for the awaiting caller without producing an unhandled rejection.
  callback.promise.catch(() => {});
  let completed = false;
  const server = createServer((req, res) => {
    const incoming = new URL(req.url, 'http://127.0.0.1');
    const returnedState = Buffer.from(incoming.searchParams.get('state') ?? '');
    const expectedState = Buffer.from(state);
    if (req.method !== 'GET' || incoming.pathname !== '/callback' || completed ||
        returnedState.length !== expectedState.length || !timingSafeEqual(returnedState, expectedState)) {
      res.writeHead(400).end('Invalid authorization callback.');
      return;
    }
    completed = true;
    res.setHeader('Cache-Control', 'no-store');
    res.setHeader('Content-Type', 'text/html; charset=utf-8');
    res.setHeader('Content-Security-Policy', "default-src 'none'; style-src 'unsafe-inline'; frame-ancestors 'none'");
    const code = incoming.searchParams.get('code');
    if (!code || incoming.searchParams.has('error')) {
      res.end('<h1>Connection cancelled</h1><p>You can close this window.</p>');
      callback.reject(new Error('Authorization was denied or did not return a code.'));
      return;
    }
    res.end('<!doctype html><title>Connected to Mave</title><body style="font:16px system-ui;background:#f5f5f4;color:#44403c;display:grid;place-content:center;min-height:90vh;text-align:center"><h1>Connected to Mave</h1><p>Return to your terminal. You can close this window.</p>');
    callback.resolve(code);
  });
  server.listen(0, '127.0.0.1');
  await once(server, 'listening');
  const redirectUrl = `http://127.0.0.1:${server.address().port}/callback`;
  const scope = write ? 'mave:read mave:write' : 'mave:read';
  let registration, tokens, verifier;
  const provider = {
    redirectUrl,
    clientMetadata: { client_name: 'Mave MCP example client', redirect_uris: [redirectUrl],
      grant_types: ['authorization_code', 'refresh_token'], response_types: ['code'],
      token_endpoint_auth_method: 'none', scope },
    state: () => state,
    clientInformation: () => registration,
    saveClientInformation: value => { registration = value; },
    tokens: () => tokens,
    saveTokens: value => { tokens = value; },
    saveCodeVerifier: value => { verifier = value; },
    codeVerifier: () => verifier,
    redirectToAuthorization: authorizationUrl => {
      // The server's 401 challenge advertises the default read scope. Explicitly
      // request write access only when the operator selected --write.
      authorizationUrl.searchParams.set('scope', scope);
      process.stderr.write(`Connect to Mave in your browser:\n${authorizationUrl.href}\n`);
      if (openBrowser) {
        const command = process.platform === 'darwin' ? 'open' : process.platform === 'win32' ? 'rundll32.exe' : 'xdg-open';
        const args = process.platform === 'win32' ? ['url.dll,FileProtocolHandler', authorizationUrl.href] : [authorizationUrl.href];
        const child = spawn(command, args, { stdio: 'ignore', shell: false });
        child.on('error', () => process.stderr.write('Open the URL above to continue.\n'));
        child.unref();
      }
    },
    invalidateCredentials: kind => {
      if (kind === 'all' || kind === 'client') registration = undefined;
      if (kind === 'all' || kind === 'tokens') tokens = undefined;
      if (kind === 'all' || kind === 'verifier') verifier = undefined;
    },
  };
  const timer = setTimeout(() => callback.reject(new Error('Browser authorization timed out.')), 600_000);
  let client = new Client({ name: 'mave-mcp-client', version: '0.1.0' });
  let transport = new StreamableHTTPClientTransport(endpoint, { authProvider: provider });
  try {
    try {
      await client.connect(transport);
    } catch (error) {
      if (!(error instanceof UnauthorizedError)) throw error;
      await transport.finishAuth(await callback.promise);
      await client.close();
      client = new Client({ name: 'mave-mcp-client', version: '0.1.0' });
      transport = new StreamableHTTPClientTransport(endpoint, { authProvider: provider });
      await client.connect(transport);
    }
    return client;
  } catch (error) {
    await client.close().catch(() => {});
    throw error;
  } finally {
    clearTimeout(timer);
    server.close();
    server.closeAllConnections();
  }
}

async function main() {
  const args = process.argv.slice(2);
  if (args.includes('--help')) {
    console.log('Usage: node client.mjs [https://api.mave.io/mcp] [--write] [--no-open] [tools | call TOOL JSON]');
    return;
  }
  const write = args.includes('--write');
  const openBrowser = !args.includes('--no-open');
  const positional = args.filter(arg => !['--write', '--no-open'].includes(arg));
  const url = /^https?:/.test(positional[0] ?? '') ? positional.shift() : undefined;
  const [command = 'tools', name, raw = '{}'] = positional;
  if (!['tools', 'call'].includes(command) || (command === 'call' && !name)) throw new Error('Use tools, or call TOOL JSON.');
  const toolArguments = JSON.parse(raw);
  const client = await connectMave({ url, write, openBrowser });
  try {
    const result = command === 'tools' ? await client.listTools() : await client.callTool({ name, arguments: toolArguments });
    console.log(JSON.stringify(result, null, 2));
    if (result.isError) process.exitCode = 1;
  } finally {
    await client.close();
  }
}

if (process.argv[1] && import.meta.url === pathToFileURL(process.argv[1]).href) {
  main().catch(error => { console.error(error.message); process.exitCode = 1; });
}
