import test from 'node:test';
import assert from 'node:assert/strict';
import { mkdtemp, readFile, stat, rm } from 'node:fs/promises';
import { tmpdir } from 'node:os';
import { join } from 'node:path';
import { config, Vault, OAuthStates, TeslaClient, AUTH, FLEET, SCOPES, requestJSON } from './core.mjs';
import { createApp } from './server.mjs';

const settings = { missing: [], clientId: 'test-client', clientSecret: 'test-secret',
  origin: 'https://test.example', adminPassword: 'a'.repeat(64), key: 'b'.repeat(64) };
const testVin = 'LRW3E7FA0NC123456'; // Synthetic fixture; no requests go to a real vehicle.
const ok = value => new Response(JSON.stringify(value), { status: 200 });
function memoryVault(initial = null) {
  let value = initial;
  return { read: async () => value, write: async next => { value = next; } };
}

test('configuration rejects insecure callback origins and malformed secrets', () => {
  assert.equal(config({}).missing.length, 5);
  for (const origin of ['http://test.example', 'https://test.example/path', 'https://user:pass@test.example']) {
    assert.throws(() => config({ PUBLIC_ORIGIN: origin }));
  }
  assert.throws(() => config({ TOKEN_ENCRYPTION_KEY: 'weak' }));
  assert.throws(() => config({ ADMIN_PASSWORD: 'weak' }));
});

test('OAuth state is browser-bound, expires and cannot be replayed', () => {
  const states = new OAuthStates();
  const a = states.issue(1000);
  assert.throws(() => states.consume(a.state, 'other-browser', 1001));
  states.consume(a.state, a.browser, 1002);
  assert.throws(() => states.consume(a.state, a.browser, 1003));
  const b = states.issue(1000);
  assert.throws(() => states.consume(b.state, b.browser, 601000));
});

test('tokens are encrypted at rest; permissions and authentication tag are enforced', async () => {
  const dir = await mkdtemp(join(tmpdir(), 'pony-test-'));
  try {
    const vault = new Vault(dir, settings.key);
    const token = { access_token: 'sensitive-access', refresh_token: 'sensitive-refresh' };
    assert.equal(await vault.read(), null);
    await vault.write(token);
    assert.deepEqual(await vault.read(), token);
    const raw = await readFile(join(dir, 'tokens.enc.json'), 'utf8');
    assert.ok(!raw.includes('sensitive-access') && !raw.includes('sensitive-refresh'));
    assert.equal((await stat(join(dir, 'tokens.enc.json'))).mode & 0o777, 0o600);
    await assert.rejects(() => new Vault(dir, 'c'.repeat(64)).read());
  } finally { await rm(dir, { recursive: true, force: true }); }
});

test('authorization uses China endpoints and read-only scopes', () => {
  const client = new TeslaClient(settings, memoryVault());
  const url = new URL(client.authorizeURL('test-state'));
  assert.equal(url.origin, 'https://auth.tesla.cn');
  assert.equal(url.searchParams.get('scope'), SCOPES);
  assert.ok(!SCOPES.includes('vehicle_cmds') && !SCOPES.includes('vehicle_charging_cmds'));
  assert.equal(url.searchParams.get('redirect_uri'), 'https://test.example/oauth/callback');
  assert.ok(!url.href.includes(settings.clientSecret));
});

test('code exchange persists rotating credentials and omits ID token', async () => {
  const vault = memoryVault();
  const client = new TeslaClient(settings, vault, async (url, options) => {
    assert.equal(url, `${AUTH}/token`);
    assert.equal(options.body.get('audience'), FLEET);
    assert.equal(options.body.get('grant_type'), 'authorization_code');
    assert.equal(options.body.get('code'), 'single-code');
    return ok({ access_token: 'access', refresh_token: 'refresh', expires_in: 3600, id_token: 'unused' });
  });
  await client.exchange('single-code');
  const token = await vault.read();
  assert.equal(token.refresh_token, 'refresh');
  assert.equal(token.id_token, undefined);
});

test('concurrent requests refresh once and persist the new refresh token', async () => {
  const vault = memoryVault({ access_token: 'old', refresh_token: 'old-refresh', expires_at: 0 });
  let requests = 0;
  const client = new TeslaClient(settings, vault, async (url, options) => {
    requests++;
    assert.equal(options.body.get('refresh_token'), 'old-refresh');
    return ok({ access_token: 'new', refresh_token: 'new-refresh', expires_in: 3600 });
  });
  assert.deepEqual(await Promise.all([client.accessToken(), client.accessToken()]), ['new', 'new']);
  assert.equal(requests, 1);
  assert.equal((await vault.read()).refresh_token, 'new-refresh');
});

test('upstream errors never expose response bodies containing credentials', async () => {
  await assert.rejects(() => requestJSON(FLEET, {}, async () => new Response('secret-token', { status: 401 })), error => {
    assert.ok(!error.message.includes('secret-token'));
    return error.message.includes('401');
  });
});

test('offline probe reports account access but does not wake or poll the vehicle', async () => {
  const calls = [];
  const client = new TeslaClient(settings, memoryVault({ access_token: 'access', expires_at: Date.now() + 3600000 }), async (url, options) => {
    calls.push([url, options.method]);
    return url.endsWith('/vehicles') ? ok({ response: [{ vin: testVin, state: 'asleep' }] }) : ok({ response: { key_paired: false } });
  });
  const result = await client.probe(testVin);
  assert.equal(result.connected, true);
  assert.equal(result.live_data, false);
  assert.equal(calls.length, 2);
  assert.ok(calls.every(([url]) => !url.includes('wake_up') && !url.includes('/command/')));
});

test('probe cannot select a vehicle outside the authorized account', async () => {
  const client = new TeslaClient(settings, memoryVault({ access_token: 'access', expires_at: Date.now() + 3600000 }), async () => ok({ response: [] }));
  await assert.rejects(() => client.probe(testVin), /不在当前授权列表/);
});

test('online probe requests live endpoints and reports actual data separately from telemetry', async () => {
  const calls = [];
  const client = new TeslaClient(settings, memoryVault({ access_token: 'access', expires_at: Date.now() + 3600000 }), async url => {
    calls.push(url);
    if (url.endsWith('/vehicles')) return ok({ response: [{ vin: testVin, state: 'online' }] });
    if (url.endsWith('/fleet_status')) return ok({ response: {} });
    return ok({ response: { charge_state: { battery_level: 61 }, access_token: 'must-not-forward' } });
  });
  const result = await client.probe(testVin);
  assert.equal(result.data.charge_state.battery_level, 61);
  assert.equal(result.live_data, true);
  assert.ok(!JSON.stringify(result).includes('must-not-forward'));
  assert.ok(new URL(calls[2]).searchParams.get('endpoints').includes('location_data'));
});

async function withServer(action) {
  let exchanges = 0;
  const vault = memoryVault();
  const client = { authorizeURL: state => `${AUTH}/authorize?state=${state}`, exchange: async () => { exchanges++; } };
  const server = createApp(settings, client, vault);
  await new Promise(resolve => server.listen(0, '127.0.0.1', resolve));
  const base = `http://127.0.0.1:${server.address().port}`;
  const authorization = `Basic ${Buffer.from(`owner:${settings.adminPassword}`).toString('base64')}`;
  try { await action({ base, authorization, exchanges: () => exchanges }); }
  finally { await new Promise(resolve => server.close(resolve)); }
}

test('backend requires authentication and rejects cross-origin POSTs', async () => withServer(async ({ base, authorization }) => {
  assert.equal((await fetch(`${base}/api/status`)).status, 401);
  const status = await fetch(`${base}/api/status`, { headers: { authorization } });
  assert.equal(status.status, 200);
  assert.ok(!(await status.text()).includes(settings.adminPassword));
  assert.equal((await fetch(`${base}/oauth/start`, { method: 'POST', headers: { authorization, origin: 'https://evil.example' } })).status, 403);
}));

test('callback needs matching browser cookie and rejects replay', async () => withServer(async ({ base, authorization, exchanges }) => {
  const start = await fetch(`${base}/oauth/start`, { method: 'POST', redirect: 'manual', headers: { authorization, origin: settings.origin } });
  assert.equal(start.status, 303);
  const cookie = start.headers.get('set-cookie');
  assert.ok(cookie.includes('HttpOnly') && cookie.includes('Secure') && cookie.includes('SameSite=Lax'));
  const state = new URL(start.headers.get('location')).searchParams.get('state');
  const callback = `${base}/oauth/callback?state=${state}&code=private-code`;
  assert.equal((await fetch(callback)).status, 400);
  assert.equal(exchanges(), 0);
  const response = await fetch(callback, { redirect: 'manual', headers: { cookie: cookie.split(';')[0] } });
  assert.equal(response.status, 303);
  assert.equal(exchanges(), 1);
  assert.equal((await fetch(callback, { headers: { cookie: cookie.split(';')[0] } })).status, 400);
}));
