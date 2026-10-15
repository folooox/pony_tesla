import test from 'node:test';
import assert from 'node:assert/strict';
import { mkdtemp, rm, readFile, writeFile } from 'node:fs/promises';
import { tmpdir } from 'node:os';
import { join } from 'node:path';
import http from 'node:http';
import { config, TeslaClient, Vault, OAuthStates, SafeError, requestJSON } from './core.mjs';
import { createApp } from './server.mjs';

const settings = { missing: [], clientId: 'fixture-client', clientSecret: 'fixture-secret',
  origin: 'https://test.example', adminPassword: 'a'.repeat(64), key: 'b'.repeat(64) };
const vin = 'LRW3E7FA0NC123456';
const json = value => new Response(JSON.stringify(value));
const validToken = () => ({ access_token: 'fixture-access', refresh_token: 'fixture-refresh', expires_at: Date.now() + 3600000 });
const memoryVault = (token = validToken()) => ({ read: async () => token, write: async next => { token = next; } });
const isSafe = status => error => error instanceof SafeError && error.status === status;

async function serverTest(action, { client = { probe: async selected => ({ vin: selected }) }, vault = memoryVault(), overrides = {} } = {}) {
  const server = createApp({ ...settings, ...overrides }, client, vault);
  await new Promise(resolve => server.listen(0, '127.0.0.1', resolve));
  const base = `http://127.0.0.1:${server.address().port}`;
  const headers = { authorization: `Basic ${Buffer.from(`owner:${settings.adminPassword}`).toString('base64')}`, origin: settings.origin, 'content-type': 'application/json' };
  try { await action({ base, headers, server }); }
  finally { server.closeAllConnections(); await new Promise(resolve => server.close(resolve)); }
}

test('invalid listen ports fail at configuration time', () => {
  for (const port of ['invalid', '-1', '0', '65536', '1.5']) assert.throws(() => config({ PORT: port }));
});

test('malformed token responses cannot overwrite existing authorization', async t => {
  for (const response of [null, [], {}, { access_token: 42, refresh_token: 'r', expires_in: 60 },
    { access_token: 'a', refresh_token: {}, expires_in: 60 },
    { access_token: 'a', refresh_token: 'r', expires_in: 0 }]) {
    await t.test(JSON.stringify(response), async () => {
      const old = validToken();
      const vault = memoryVault(old);
      const client = new TeslaClient(settings, vault, async () => json(response));
      await assert.rejects(() => client.exchange('fixture-code'), isSafe(502));
      assert.deepEqual(await vault.read(), old);
    });
  }
});

test('malformed vehicle responses are safe errors, not internal exceptions', async t => {
  for (const response of [null, {}, { response: null }, { response: [null] }, { response: ['car'] }]) {
    await t.test(JSON.stringify(response), async () => {
      const client = new TeslaClient(settings, memoryVault(), async () => json(response));
      await assert.rejects(() => client.vehicles(), isSafe(502));
    });
  }
});

test('empty or malformed live state cannot be reported as successful vehicle data', async t => {
  for (const response of [null, { response: null }, { response: {} },
    { response: { charge_state: {} } }, { response: { charge_state: [61] } }]) {
    await t.test(JSON.stringify(response), async () => {
      const client = new TeslaClient(settings, memoryVault(), async url => {
        if (url.endsWith('/vehicles')) return json({ response: [{ vin, state: 'online' }] });
        if (url.endsWith('/fleet_status')) return json({ response: {} });
        return json(response);
      });
      await assert.rejects(() => client.probe(vin), isSafe(502));
    });
  }
});

test('invalid VIN makes no Tesla API requests', async () => {
  let calls = 0;
  const client = new TeslaClient(settings, memoryVault(), async () => { calls++; return json({}); });
  for (const selected of [null, '', '../path', 'I'.repeat(17), { vin }]) await assert.rejects(() => client.probe(selected), isSafe(400));
  assert.equal(calls, 0);
});

test('a failed refresh preserves credentials and does not poison later reauthorization', async () => {
  const old = { ...validToken(), expires_at: 0 };
  const vault = memoryVault(old);
  let calls = 0;
  const client = new TeslaClient(settings, vault, async () => ++calls === 1
    ? new Response('secret-upstream-body', { status: 401 })
    : json({ access_token: 'new', refresh_token: 'rotated', expires_in: 3600 }));
  await assert.rejects(() => client.accessToken(), isSafe(502));
  assert.deepEqual(await vault.read(), old);
  await client.exchange('new-code');
  assert.equal(await client.accessToken(), 'new');
  assert.equal(calls, 2);
});

test('network failures, non-JSON bodies and upstream HTTP errors have safe messages', async () => {
  for (const status of [401, 403, 408, 429, 500, 503]) {
    await assert.rejects(() => requestJSON('https://fixture.invalid', {}, async () => new Response('private details', { status })), error => {
      assert.equal(error.status, 502); assert.ok(error.message.includes(String(status)));
      return !error.message.includes('private details');
    });
  }
  await assert.rejects(() => requestJSON('https://fixture.invalid', {}, async () => { throw new Error('private network details'); }), isSafe(502));
  await assert.rejects(() => requestJSON('https://fixture.invalid', {}, async () => new Response('<html>not JSON</html>')), isSafe(502));
});

test('OAuth pending-session limit recovers when old sessions expire', () => {
  const states = new OAuthStates();
  for (let i = 0; i < 50; i++) states.issue(0);
  assert.throws(() => states.issue(1), isSafe(429));
  assert.ok(states.issue(600000).state);
});

test('encrypted tokens survive a new Vault instance and reject ciphertext tampering', async () => {
  const dir = await mkdtemp(join(tmpdir(), 'pony-vault-'));
  try {
    await new Vault(dir, settings.key).write(validToken());
    assert.equal((await new Vault(dir, settings.key).read()).access_token, 'fixture-access');
    const path = join(dir, 'tokens.enc.json');
    const data = JSON.parse(await readFile(path, 'utf8'));
    const bytes = Buffer.from(data.ciphertext, 'base64'); bytes[0] ^= 1; data.ciphertext = bytes.toString('base64');
    await writeFile(path, JSON.stringify(data));
    await assert.rejects(() => new Vault(dir, settings.key).read());
  } finally { await rm(dir, { recursive: true, force: true }); }
});

test('invalid probe bodies return 400 and do not consume the read cooldown', async () => serverTest(async ({ base, headers }) => {
  for (const body of ['null', '[]', '42', '{}', '{', JSON.stringify({ vin: 'invalid' })]) {
    const response = await fetch(`${base}/api/probe`, { method: 'POST', headers, body });
    assert.equal(response.status, 400, body);
  }
  assert.equal((await fetch(`${base}/api/probe`, { method: 'POST', headers, body: JSON.stringify({ vin }) })).status, 200);
}));

test('probe limits count bytes and return a readable 413 JSON response', async () => serverTest(async ({ base, headers }) => {
  const response = await fetch(`${base}/api/probe`, { method: 'POST', headers, body: JSON.stringify({ vin, padding: '车'.repeat(500) }) });
  assert.equal(response.status, 413);
  assert.match((await response.json()).error, /请求过大/);
}));

test('parallel probes cannot both contact the vehicle', async () => {
  let finish;
  let started;
  const waiting = new Promise(resolve => { started = resolve; });
  let calls = 0;
  await serverTest(async ({ base, headers }) => {
    const options = { method: 'POST', headers, body: JSON.stringify({ vin }) };
    const first = fetch(`${base}/api/probe`, options);
    await waiting;
    assert.equal((await fetch(`${base}/api/probe`, options)).status, 429);
    finish();
    assert.equal((await first).status, 200);
    assert.equal((await fetch(`${base}/api/probe`, options)).status, 429);
    assert.equal(calls, 1);
  }, { client: { probe: async () => { calls++; started(); await new Promise(resolve => { finish = resolve; }); return { live_data: true }; } } });
});

test('overlapping streamed request bodies still allow only one vehicle read', async () => {
  let calls = 0;
  await serverTest(async ({ base, headers }) => {
    function slowRequest() {
      let request;
      const response = new Promise((resolve, reject) => {
        request = http.request(`${base}/api/probe`, { method: 'POST', headers }, res => {
          res.resume(); res.on('end', () => resolve(res.statusCode));
        });
        request.on('error', reject);
        request.write('{"vin":');
      });
      return { request, response };
    }
    const first = slowRequest(); const second = slowRequest();
    // Both requests pass the early rate check before either has a complete body.
    await new Promise(resolve => setTimeout(resolve, 30));
    first.request.end(`${JSON.stringify(vin)}}`);
    assert.equal(await first.response, 200);
    second.request.end(`${JSON.stringify(vin)}}`);
    assert.equal(await second.response, 429);
    assert.equal(calls, 1);
  }, { client: { probe: async () => { calls++; return { live_data: true }; } } });
});

test('malformed fleet capabilities do not produce a successful connection result', async () => {
  for (const payload of [null, {}, { response: null }]) {
    const client = new TeslaClient(settings, memoryVault(), async url => url.endsWith('/vehicles')
      ? json({ response: [{ vin, state: 'asleep' }] }) : json(payload));
    await assert.rejects(() => client.probe(vin), isSafe(502));
  }
});

test('public health is honest before application configuration; private routes stay protected', async () => serverTest(async ({ base, headers }) => {
  assert.deepEqual(await (await fetch(`${base}/healthz`)).json(), { status: 'needs_configuration' });
  for (const path of ['/', '/app.js', '/style.css', '/api/vehicles', '/.env', '/.private/private-key.pem']) {
    assert.equal((await fetch(`${base}${path}`)).status, 401, path);
  }
  const status = await (await fetch(`${base}/api/status`, { headers })).json();
  assert.equal(status.authorized, false);
  assert.deepEqual(status.missing, ['TESLA_CLIENT_ID']);
  assert.equal((await fetch(`${base}/oauth/start`, { method: 'POST', headers })).status, 503);
}, { client: null, vault: memoryVault(null), overrides: { missing: ['TESLA_CLIENT_ID'] } }));

test('missing and mismatched origins are rejected, as are wrong Basic usernames', async () => serverTest(async ({ base, headers }) => {
  for (const origin of [undefined, 'null', 'https://test.example.evil']) {
    const candidate = { ...headers }; if (origin === undefined) delete candidate.origin; else candidate.origin = origin;
    assert.equal((await fetch(`${base}/api/probe`, { method: 'POST', headers: candidate, body: JSON.stringify({ vin }) })).status, 403);
  }
  const authorization = `Basic ${Buffer.from(`other:${settings.adminPassword}`).toString('base64')}`;
  assert.equal((await fetch(`${base}/api/status`, { headers: { authorization } })).status, 401);
}));

test('cancelled authorization clears its cookie and never exchanges a code', async () => {
  let calls = 0;
  await serverTest(async ({ base, headers }) => {
    const start = await fetch(`${base}/oauth/start`, { method: 'POST', headers, redirect: 'manual' });
    const state = new URL(start.headers.get('location')).searchParams.get('state');
    const cookie = start.headers.get('set-cookie').split(';')[0];
    const response = await fetch(`${base}/oauth/callback?state=${state}&error=access_denied`, { headers: { cookie } });
    assert.equal(response.status, 400);
    assert.ok(response.headers.get('set-cookie').includes('Max-Age=0'));
    assert.match((await response.json()).error, /授权未完成/);
    assert.equal(calls, 0);
  }, { client: { authorizeURL: state => `https://auth.tesla.cn/oauth2/v3/authorize?state=${state}`, exchange: async () => { calls++; } } });
});
