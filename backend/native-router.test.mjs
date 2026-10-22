import test from 'node:test';
import assert from 'node:assert/strict';
import { generateKeyPairSync, sign } from 'node:crypto';
import { mkdtemp, rm, readFile, writeFile } from 'node:fs/promises';
import { tmpdir } from 'node:os';
import { join } from 'node:path';
import { createApp } from './server.mjs';
import { createNativeRouter } from './native-router.mjs';
import { NativeAuth, CALLBACK, JWKS, hash } from './native-auth.mjs';
import { AUTH, FLEET, Vault } from './core.mjs';
import { HistoryStore } from './history.mjs';

const rsa = generateKeyPairSync('rsa', { modulusLength: 2048 });
const jwk = { ...rsa.publicKey.export({ format: 'jwk' }), kid: 'router-fixture', use: 'sig', alg: 'RS256' };
const vin = 'LRW3E7FA0NC123456', otherVin = 'LRW3E7FA0NC123457';
const initialNow = Date.parse('2026-10-18T12:00:00Z');
const verifier = 'v'.repeat(43), appState = 'fixture_app_state_123456';
function token(nonce, subject, now) {
  const parts = [{ alg: 'RS256', kid: jwk.kid }, { iss: AUTH, sub: subject, aud: 'fixture-client', nonce, iat: Math.floor(now / 1000), exp: Math.floor(now / 1000) + 3600 }]
    .map(v => Buffer.from(JSON.stringify(v)).toString('base64url')).join('.');
  return `${parts}.${sign('RSA-SHA256', Buffer.from(parts), rsa.privateKey).toString('base64url')}`;
}

async function fixture(action, options = {}) {
  const dir = await mkdtemp(join(tmpdir(), 'pony-native-router-'));
  const settings = { missing: [], clientId: 'fixture-client', clientSecret: 'fixture-secret', origin: 'https://fixture.example',
    adminPassword: 'a'.repeat(64), key: 'b'.repeat(64), dir, nativeEnabled: true, nativeApprovedOrigin: 'https://fixture.example', ...options.settings };
  let time = initialNow, subject = 'A', nonce, invalidIdentity = false, exchangeCalls = 0;
  let legacyWrites = 0, legacyExchanges = 0;
  const legacy = { read: async () => ({ access_token: 'legacy-owner-secret' }), write: async () => { legacyWrites++; } };
  const legacyClient = { authorizeURL: state => `${AUTH}/authorize?state=${state}`, exchange: async () => { legacyExchanges++; } };
  const auth = new NativeAuth(join(dir, 'native', 'sessions.sqlite'), { clock: () => time });
  const contexts = new Map(), lists = { A: [vin, otherVin], B: [vin] };
  let probeCalls = 0, listCalls = 0, releaseProbe = null, releaseList = null;
  const router = createNativeRouter(settings, { auth, clock: () => time,
    transport: async (url, request) => {
      if (url === JWKS) return new Response(JSON.stringify({ keys: [jwk] }));
      assert.equal(url, `${AUTH}/token`); exchangeCalls++;
      assert.equal(request.body.get('client_secret'), settings.clientSecret);
      assert.equal(request.body.get('audience'), FLEET);
      assert.equal(request.body.get('redirect_uri'), `${settings.origin}/oauth/callback`);
      return new Response(JSON.stringify({ access_token: `tesla-${subject}`, refresh_token: `tesla-refresh-${subject}`, expires_in: 3600,
        ...(invalidIdentity ? {} : { id_token: token(nonce, subject, time) }) }));
    },
    accountFactory: id => {
      const vault = new Vault(join(dir, 'native', 'accounts', id), settings.key);
      const who = async () => (await vault.read()).access_token.slice('tesla-'.length);
      const client = {
        serialized: action => action(),
        vehicles: async () => {
          listCalls++; if (releaseList) await releaseList;
          return lists[await who()].map(v => ({ vin: v, state: 'online' }));
        },
        probe: async selected => {
          probeCalls++; if (releaseProbe) await releaseProbe;
          return { connected: true, live_data: true, vehicle: { vin: selected, state: 'online' }, capability: {},
            fetched_at: new Date(time).toISOString(), data: { charge_state: { battery_level: await who() === 'A' ? 11 : 22 } }, message: 'fixture only' };
        },
      };
      const value = { vault, client, history: new HistoryStore(join(dir, 'native', 'accounts', id, 'history.sqlite'), { clock: () => time }) };
      contexts.set(id, value); return value;
    },
  });
  const server = createApp(settings, legacyClient, legacy, null, router);
  await new Promise(resolve => server.listen(0, '127.0.0.1', resolve));
  const base = `http://127.0.0.1:${server.address().port}`;
  const basic = `Basic ${Buffer.from(`owner:${settings.adminPassword}`).toString('base64')}`;
  const request = (path, { body, bearer, headers = {}, ...rest } = {}) => fetch(base + path, { redirect: 'manual',
    ...rest, headers: { ...(body !== undefined ? { 'content-type': 'application/json' } : {}), ...(bearer ? { authorization: `Bearer ${bearer}` } : {}), ...headers },
    ...(body !== undefined ? { body: JSON.stringify(body) } : {}) });
  const post = (path, body, rest) => request(`/api/native/v1${path}`, { method: 'POST', body, ...rest });
  const get = (path, bearer) => request(`/api/native/v1${path}`, { bearer });
  async function begin(who = 'A') {
    subject = who;
    const start = await post('/auth/start', { code_challenge: hash(verifier), callback: CALLBACK, state: appState });
    assert.equal(start.status, 200);
    const value = await start.json();
    assert.equal(new URL(value.authorization_url).origin, settings.origin);
    assert.ok(!value.authorization_url.includes(settings.clientSecret));
    const browser = await request(new URL(value.authorization_url).pathname + new URL(value.authorization_url).search);
    assert.equal(browser.status, 303);
    const location = new URL(browser.headers.get('location'));
    assert.equal(location.origin, 'https://auth.tesla.cn');
    assert.equal(location.searchParams.get('redirect_uri'), `${settings.origin}/oauth/callback`);
    assert.equal(location.searchParams.get('scope').includes('vehicle_cmds'), false);
    nonce = location.searchParams.get('nonce');
    return { state: location.searchParams.get('state'), cookie: browser.headers.get('set-cookie').split(';')[0], browser, value };
  }
  async function callback(flow, query = 'code=fixture-code') {
    return request(`/oauth/callback?state=${encodeURIComponent(flow.state)}&${query}`, { headers: { cookie: flow.cookie } });
  }
  async function login(who = 'A') {
    const flow = await begin(who), cb = await callback(flow);
    assert.equal(cb.status, 303);
    assert.ok(cb.headers.get('set-cookie').includes('Max-Age=0'));
    const location = new URL(cb.headers.get('location'));
    assert.equal(`${location.protocol}//${location.host}`, CALLBACK);
    assert.equal(location.searchParams.get('state'), appState);
    assert.deepEqual([...location.searchParams.keys()].sort(), ['grant', 'state']);
    const result = await post('/auth/exchange', { grant: location.searchParams.get('grant'), code_verifier: verifier, callback: CALLBACK });
    assert.equal(result.status, 200); return result.json();
  }
  try { await action({ dir, settings, auth, contexts, lists, request, post, get, begin, callback, login, basic,
    setTime: value => { time = value; }, advance: value => { time += value; },
    invalidIdentity: () => { invalidIdentity = true; }, setProbeWait: value => { releaseProbe = value; }, setListWait: value => { releaseList = value; },
    counters: () => ({ legacyWrites, legacyExchanges, exchangeCalls, probeCalls, listCalls }) }); }
  finally { server.closeAllConnections(); await new Promise(resolve => server.close(resolve)); if (!settings.nativeEnabled) auth.close(); await rm(dir, { recursive: true, force: true }); }
}

test('native end-to-end verified login stable account, no owner vault adoption, admin/native separation', async () => fixture(async f => {
  const a = await f.login('A'), again = await f.login('A'), b = await f.login('B');
  assert.equal(a.account_id, again.account_id); assert.notEqual(a.account_id, b.account_id);
  const sessionResponse = await f.get('/session', a.access_token), session = await sessionResponse.json();
  assert.equal(session.account_id, a.account_id); assert.equal(session.features.commands, false);
  assert.equal(session.features.telemetry, false); assert.equal(session.features.charge_history, false);
  assert.equal(sessionResponse.headers.get('cache-control'), 'no-store'); assert.equal(sessionResponse.headers.get('referrer-policy'), 'no-referrer');
  assert.equal(sessionResponse.headers.has('access-control-allow-origin'), false);
  assert.equal((await f.get('/session')).status, 401);
  assert.equal((await f.request('/api/native/v1/session', { headers: { authorization: f.basic } })).status, 401);
  assert.equal((await f.request('/api/status', { bearer: a.access_token })).status, 401);
  assert.equal((await f.request('/api/status', { headers: { authorization: f.basic } })).status, 200);
  assert.equal(f.counters().legacyWrites, 0); assert.equal(f.counters().legacyExchanges, 0);
  const vehicles = await (await f.get('/vehicles', b.access_token)).json(); assert.equal(vehicles.vehicles.length, 1);
  assert.equal(f.counters().probeCalls, 0);
  assert.equal((await f.get('/session?account_id=other', a.access_token)).status, 400);
}));

test('missing ID token fails closed before account/token save, legacy files unchanged', async () => fixture(async f => {
  await writeFile(join(f.dir, 'tokens.enc.json'), 'fixture legacy sentinel');
  await writeFile(join(f.dir, 'history.sqlite'), 'fixture legacy history sentinel');
  f.invalidIdentity(); const flow = await f.begin();
  const response = await f.callback(flow);
  assert.equal(response.status, 401); assert.ok(response.headers.get('set-cookie').includes('Max-Age=0'));
  assert.equal(f.contexts.size, 0); assert.equal(f.auth.db.prepare('SELECT count(*) AS n FROM accounts').get().n, 0);
  assert.equal(f.counters().legacyWrites, 0);
  assert.equal(await readFile(join(f.dir, 'tokens.enc.json'), 'utf8'), 'fixture legacy sentinel');
  assert.equal(await readFile(join(f.dir, 'history.sqlite'), 'utf8'), 'fixture legacy history sentinel');
}));

test('native cookies, cancellation, missing/wrong state, replay and grant PKCE fail safely; legacy state untouched', async () => fixture(async f => {
  const cancelled = await f.begin();
  for (const attribute of ['HttpOnly', 'Secure', 'SameSite=Lax', 'Path=/oauth/callback']) assert.ok(cancelled.browser.headers.get('set-cookie').includes(attribute));
  assert.equal((await f.callback(cancelled, 'error=access_denied')).status, 400);
  assert.equal((await f.callback(cancelled)).status, 401);
  assert.equal(f.counters().exchangeCalls, 0);
  const flow = await f.begin();
  const wrong = await f.request(`/oauth/callback?state=${flow.state}&code=fixture-code`, { headers: { cookie: '__Secure-pony_native=wrong' } });
  assert.equal(wrong.status, 401); assert.ok(wrong.headers.get('set-cookie').includes('Max-Age=0'));
  assert.equal((await f.callback(flow)).status, 401);
  assert.equal((await f.request('/oauth/callback?state=native.invalid&code=fixture-code')).status, 401);
  const noState = await f.request('/oauth/callback?code=fixture-code', { headers: { cookie: flow.cookie } });
  assert.equal(noState.status, 401);
  const legacyStart = await f.request('/oauth/start', { method: 'POST', headers: { authorization: f.basic, origin: f.settings.origin } });
  const state = new URL(legacyStart.headers.get('location')).searchParams.get('state');
  const legacyCallback = await f.request(`/oauth/callback?state=${state}&code=legacy-code`, { headers: { cookie: legacyStart.headers.get('set-cookie').split(';')[0] } });
  assert.equal(legacyCallback.status, 303); assert.equal(f.counters().legacyExchanges, 1);
  const good = await f.begin(), cb = await f.callback(good), grant = new URL(cb.headers.get('location')).searchParams.get('grant');
  assert.equal((await f.post('/auth/exchange', { grant, callback: CALLBACK, code_verifier: 'wrong'.repeat(10) })).status, 401);
  assert.equal((await f.post('/auth/exchange', { grant, callback: CALLBACK, code_verifier: verifier })).status, 401);
}));

test('account A/B isolation for same VIN, removed vehicle cache denied, probe cooldown/lock and unsupported APIs', async () => fixture(async f => {
  const a = await f.login('A'), b = await f.login('B');
  assert.equal((await f.get(`/vehicles/${vin}/snapshot`, a.access_token)).status, 404);
  const pa = await f.post(`/vehicles/${vin}/probe`, {}, { bearer: a.access_token }); assert.equal(pa.status, 200);
  assert.equal((await f.get(`/vehicles/${vin}/snapshot`, b.access_token)).status, 404);
  assert.equal((await f.post(`/vehicles/${vin}/probe`, {}, { bearer: b.access_token })).status, 200);
  assert.equal((await (await f.get(`/vehicles/${vin}/snapshot`, a.access_token)).json()).snapshot.data.charge_state.battery_level, 11);
  assert.equal((await (await f.get(`/vehicles/${vin}/snapshot`, b.access_token)).json()).snapshot.data.charge_state.battery_level, 22);
  assert.equal((await f.get(`/vehicles/${otherVin}/snapshot`, b.access_token)).status, 403);
  assert.equal((await f.post(`/vehicles/${vin}/probe`, {}, { bearer: a.access_token })).status, 429);
  f.advance(15_000);
  let release; f.setProbeWait(new Promise(resolve => { release = resolve; }));
  const pending = f.post(`/vehicles/${vin}/probe`, {}, { bearer: a.access_token });
  // Wait for route-owned lock, not a timing assumption about fetch scheduling.
  await new Promise((resolve, reject) => {
    const deadline = Date.now() + 5000;
    const check = () => {
      if (f.contexts.get(a.account_id).active) resolve();
      else if (Date.now() >= deadline) reject(new Error('Fixture probe did not acquire lock'));
      else setImmediate(check);
    }; check();
  });
  assert.equal((await f.post(`/vehicles/${vin}/probe`, {}, { bearer: a.access_token })).status, 429);
  release(); assert.equal((await pending).status, 200); f.setProbeWait(null);
  f.lists.A = []; assert.equal((await f.get(`/vehicles/${vin}/snapshot`, a.access_token)).status, 403);
  f.advance(15_000); assert.equal((await f.post(`/vehicles/${vin}/probe`, {}, { bearer: a.access_token })).status, 403);
  for (const path of ['/trips', '/history', '/vehicles/' + vin + '/wake_up', '/vehicles/' + vin + '/command/lock', '/telemetry', '/account/delete']) {
    assert.equal((await f.get(path, a.access_token)).status, 404);
  }
}));

test('native refresh rotation, replay revokes winner, logout leaves Tesla/data alone', async () => fixture(async f => {
  const a = await f.login();
  const first = await f.post('/auth/refresh', { refresh_token: a.refresh_token }); assert.equal(first.status, 200);
  const rotated = await first.json();
  assert.equal((await f.post('/auth/refresh', { refresh_token: a.refresh_token })).status, 401);
  assert.equal((await f.get('/session', rotated.access_token)).status, 401);
  const again = await f.login();
  const logout = await f.post('/auth/logout', {}, { bearer: again.access_token });
  assert.deepEqual(await logout.json(), { logged_out: true, tesla_revoked: false, data_deleted: false });
  assert.equal((await f.get('/session', again.access_token)).status, 401);
  assert.equal((await f.post('/auth/refresh', { refresh_token: again.refresh_token })).status, 401);
  assert.ok(await f.contexts.get(again.account_id).vault.read());
}));

test('native JSON, CSRF, size, disabled/config gates and bounded auth rate limits', async () => {
  await fixture(async f => {
    for (const origin of ['https://evil.invalid', 'null']) assert.equal((await f.post('/auth/start', {}, { headers: { origin } })).status, 403);
    assert.equal((await f.request('/api/native/v1/auth/start', { method: 'POST', headers: { 'content-type': 'text/plain' }, body: {} })).status, 415);
    assert.equal((await f.post('/auth/start', { padding: 'x'.repeat(5000) })).status, 413);
    for (let i = 0; i < 100; i++) await f.post('/auth/exchange', { grant: 'bad' });
    // Invalid completions do not share admission budget with new starts.
    assert.equal((await f.post('/auth/start', {})).status, 401);
    for (let i = 0; i < 20; i++) await f.post('/auth/start', {});
    assert.equal((await f.post('/auth/start', {})).status, 429);
    f.advance(60_000); assert.equal((await f.post('/auth/start', {})).status, 401);
  });
  await fixture(async f => {
    assert.equal((await f.get('/session')).status, 404);
    assert.equal((await f.request('/oauth/callback?state=native.unknown&code=fixture-code')).status, 404);
    assert.equal((await f.request('/api/status', { headers: { authorization: f.basic } })).status, 200);
  }, { settings: { nativeEnabled: false } });
  assert.throws(() => createNativeRouter({ nativeEnabled: true, origin: 'https://fixture.example', nativeApprovedOrigin: 'https://other.example', key: 'b'.repeat(64), missing: [] }));
});

test('Fleet list/snapshot bursts are capped per account, never reuse stale membership, and have a sustained budget', async () => fixture(async f => {
  const a = await f.login('A'), b = await f.login('B');
  assert.equal((await f.post(`/vehicles/${vin}/probe`, {}, { bearer: a.access_token })).status, 200);
  const baseline = f.counters().listCalls;
  let release;
  f.setListWait(new Promise(resolve => { release = resolve; }));
  const first = f.get('/vehicles', a.access_token);
  await new Promise((resolve, reject) => {
    const deadline = Date.now() + 5000;
    const check = () => {
      if (f.contexts.get(a.account_id).fleetActive) resolve();
      else if (Date.now() >= deadline) reject(new Error('Fixture list did not acquire lock'));
      else setImmediate(check);
    }; check();
  });
  try {
    const burst = await Promise.all(Array.from({ length: 16 }, (_, i) => f.get(i % 2 ? `/vehicles/${vin}/snapshot` : '/vehicles', a.access_token)));
    assert.ok(burst.every(response => response.status === 429));
    assert.equal(f.counters().listCalls, baseline + 1);
  } finally { release(); f.setListWait(null); }
  assert.equal((await first).status, 200);
  f.lists.A = [];
  // A's snapshot exists, but the newly removed membership is checked upstream now.
  assert.equal((await f.get(`/vehicles/${vin}/snapshot`, a.access_token)).status, 403);
  assert.equal(f.counters().listCalls, baseline + 2);
  f.advance(60_000);
  for (let i = 0; i < 30; i++) assert.equal((await f.get('/vehicles', a.access_token)).status, 200);
  const calls = f.counters().listCalls;
  assert.equal((await f.get('/vehicles', a.access_token)).status, 429);
  assert.equal((await f.get(`/vehicles/${vin}/snapshot`, a.access_token)).status, 429);
  assert.equal(f.counters().listCalls, calls);
  assert.equal((await f.get('/vehicles', b.access_token)).status, 200);
}));

test('anonymous starts/bogus exchanges cannot exhaust completion reserves or starve valid callback, exchange and refresh', async () => fixture(async f => {
  const established = await f.login('A');
  const exchangeFlow = await f.begin('A');
  const grantResponse = await f.callback(exchangeFlow);
  assert.equal(grantResponse.status, 303);
  const readyGrant = new URL(grantResponse.headers.get('location')).searchParams.get('grant');
  const callbackFlow = await f.begin('A');
  const startBody = { code_challenge: hash(verifier), callback: CALLBACK, state: appState };
  for (let i = 0; i < 30; i++) await f.post('/auth/start', startBody, { headers: { 'x-forwarded-for': `198.51.100.${i}`, forwarded: `for=198.51.100.${i}` } });
  assert.equal((await f.post('/auth/start', startBody, { headers: { 'x-forwarded-for': '203.0.113.99' } })).status, 429);
  // Simulate additional admitted remote peers filling the durable request pool.
  while (f.auth.db.prepare("SELECT count(*) AS n FROM pending WHERE kind='request'").get().n < 50) f.auth.start(startBody);
  assert.throws(() => f.auth.start(startBody), { status: 429 });
  const before = f.counters().exchangeCalls;
  for (let i = 0; i < 60; i++) {
    const result = await f.post('/auth/exchange', { grant: 'bogus', code_verifier: verifier, callback: CALLBACK },
      { headers: { 'x-forwarded-for': `198.51.100.${i}`, forwarded: `for=198.51.100.${i}` } });
    assert.equal(result.status, i < 40 ? 401 : 429);
  }
  assert.equal(f.counters().exchangeCalls, before);
  const exchange = await f.post('/auth/exchange', { grant: readyGrant, code_verifier: verifier, callback: CALLBACK });
  assert.equal(exchange.status, 200);
  const completed = await f.callback(callbackFlow);
  assert.equal(completed.status, 303);
  const callbackGrant = new URL(completed.headers.get('location')).searchParams.get('grant');
  assert.equal((await f.post('/auth/exchange', { grant: callbackGrant, code_verifier: verifier, callback: CALLBACK })).status, 200);
  const refreshed = await f.post('/auth/refresh', { refresh_token: established.refresh_token });
  assert.equal(refreshed.status, 200);
  const rotated = await refreshed.json();
  assert.equal((await f.get('/session', rotated.access_token)).status, 200);
  // Replay detection must also survive the saturated invalid-credential bucket.
  assert.equal((await f.post('/auth/refresh', { refresh_token: established.refresh_token })).status, 401);
  assert.equal((await f.get('/session', rotated.access_token)).status, 401);
  assert.equal(f.auth.db.prepare("SELECT count(*) AS n FROM pending WHERE kind='request'").get().n, 50);
}));

test('credential refresh quota returns429 independently of anonymous buckets; replay still revokes at exhausted quota', async () => fixture(async f => {
  const initial = await f.login('A');
  let current = initial;
  for (let i = 0; i < 6; i++) {
    const response = await f.post('/auth/refresh', { refresh_token: current.refresh_token });
    assert.equal(response.status, 200); current = await response.json();
  }
  assert.equal((await f.post('/auth/refresh', { refresh_token: current.refresh_token })).status, 429);
  assert.equal((await f.get('/session', current.access_token)).status, 200);
  assert.equal((await f.post('/auth/refresh', { refresh_token: initial.refresh_token })).status, 401);
  assert.equal((await f.get('/session', current.access_token)).status, 401);
}));
