import test from 'node:test';
import assert from 'node:assert/strict';
import { mkdtemp, rm, readFile } from 'node:fs/promises';
import { join } from 'node:path';
import { tmpdir } from 'node:os';
import { NativeAuth, CALLBACK, hash } from './native-auth.mjs';
import { OwnerPairing } from './owner-pairing.mjs';
import { createApp } from './server.mjs';

const verifier = 'v'.repeat(43), code = '12AB34CD';
const input = () => ({ code_challenge: hash(verifier), callback: CALLBACK, state: 'synthetic_state_123456', verification_code: code });
const exchange = grant => ({ grant, code_verifier: verifier, callback: CALLBACK });
const settings = () => ({ nativeEnabled: true, ownerPairingEnabled: true, adminPassword: 'synthetic-admin', key: 'b'.repeat(64),
  origin: 'https://synthetic.example', nativeApprovedOrigin: 'https://synthetic.example', clientId: 'fixture', missing: [] });
function unit(action) {
  let now = 1000000;
  const auth = new NativeAuth(':memory:', { clock: () => now }), config = settings();
  const owner = new OwnerPairing(auth, config, { clock: () => now });
  const begin = () => owner.browser(owner.start(input()));
  const decide = (flow, extra = {}) => owner.decide({ intent: flow.intent, csrf: flow.csrf, decision: 'approve', verification_code: code, ...extra }, flow.browser);
  try { action({ auth, owner, config, begin, decide, advance: ms => { now += ms; } }); }
  finally { auth.close(); }
}

test('owner provenance is separate, owner grants cannot be redeemed by Tesla exchange, wrong PKCE commits consumption', () => unit(f => {
  const grant = f.decide(f.begin()).grant;
  assert.throws(() => f.auth.exchange(exchange(grant)));
  const tokens = f.owner.exchange(exchange(grant));
  assert.equal(tokens.expires_in, 900); assert.equal(tokens.refresh_expires_in, 30 * 86400);
  assert.equal(f.auth.authenticate(tokens.access_token).principal_type, 'service_owner');
  assert.equal(f.auth.db.prepare('SELECT count(*) AS n FROM accounts').get().n, 0);
  assert.throws(() => f.owner.exchange(exchange(grant)));
  const stolen = f.decide(f.begin()).grant;
  assert.throws(() => f.owner.exchange({ ...exchange(stolen), code_verifier: 'x'.repeat(43) }));
  assert.throws(() => f.owner.exchange(exchange(stolen)));
  const legacyAccount = f.auth.account({ issuer: 'synthetic-issuer', subject: 'subject' });
  const legacyGrant = f.auth.grant(legacyAccount, { code_challenge: hash(verifier) });
  assert.throws(() => f.owner.exchange(exchange(legacyGrant)));
  assert.equal(f.auth.exchange(exchange(legacyGrant)).account_id, legacyAccount);
}));

test('owner original TTL never slides; grant expires60 seconds, denial is explicit and creates no family', () => unit(f => {
  const request = f.owner.start(input()); f.advance(599000);
  const flow = f.owner.browser(request); f.advance(1000);
  assert.throws(() => f.decide(flow));
  const deniedFlow = f.begin();
  assert.deepEqual(f.decide(deniedFlow, { decision: 'deny', verification_code: '' }), { error: 'pairing_rejected', state: input().state });
  assert.throws(() => f.decide(deniedFlow));
  assert.equal(f.auth.db.prepare('SELECT count(*) AS n FROM families').get().n, 0);
  const grant = f.decide(f.begin()).grant; f.advance(60000);
  assert.throws(() => f.owner.exchange(exchange(grant)));
}));

test('owner cookie/CSRF binding, strict schema, five failed codes and cooldown', () => unit(f => {
  assert.throws(() => f.owner.start({ ...input(), verification_code: '12ab34cd' }));
  assert.throws(() => f.owner.start({ ...input(), device_name: 'untrusted' }));
  const a = f.begin(), b = f.begin();
  assert.throws(() => f.owner.decide({ intent: a.intent, csrf: a.csrf, decision: 'approve', verification_code: code }, b.browser));
  assert.throws(() => f.decide(a, { csrf: b.csrf }));
  assert.throws(() => f.decide(a, { verification_code: '00000000' }));
  assert.throws(() => f.decide(a), { status: 429 });
  for (let i = 0; i < 4; i++) { f.advance(2000); assert.throws(() => f.decide(a, { verification_code: '00000000' })); }
  f.advance(2000); assert.throws(() => f.decide(a));
  assert.ok(f.decide(b).grant);
  const retry = f.begin();
  assert.throws(() => f.decide(retry, { verification_code: 'nothex' }));
  f.advance(2000);
  assert.ok(f.decide(retry).grant);
  const malformedDeny = f.begin();
  assert.equal(f.decide(malformedDeny, { decision: 'deny', verification_code: 'nothex' }).error, 'pairing_rejected');
}));

test('admin revoke pre/post exchange, old enrollment invalidation and refresh replay cannot revive an owner family', () => unit(f => {
  const approved = f.decide(f.begin()), oldRequest = f.owner.start(input()), oldIntent = f.begin();
  const page = f.owner.management(), family = page.devices[0].family;
  assert.throws(() => f.owner.revoke({ intent: page.intent, csrf: page.csrf, family }, 'x'.repeat(43)));
  f.owner.revoke({ intent: page.intent, csrf: page.csrf, family }, page.browser);
  assert.throws(() => f.owner.exchange(exchange(approved.grant)));
  assert.throws(() => f.owner.browser(oldRequest)); assert.throws(() => f.decide(oldIntent));
  const tokens = f.owner.exchange(exchange(f.decide(f.begin()).grant));
  const rotated = f.auth.refresh(tokens.refresh_token);
  assert.throws(() => f.auth.refresh(tokens.refresh_token));
  assert.throws(() => f.auth.authenticate(rotated.access_token));
  const next = f.owner.exchange(exchange(f.decide(f.begin()).grant));
  const management = f.owner.management();
  const nextFamily = f.auth.authenticate(next.access_token).family;
  f.owner.revoke({ intent: management.intent, csrf: management.csrf, family: nextFamily }, management.browser);
  assert.throws(() => f.auth.authenticate(next.access_token)); assert.throws(() => f.auth.refresh(next.refresh_token));
}));

test('gate off and password change kill owner session, refresh, grant and pending; Tesla sessions remain untouched', () => unit(f => {
  const legacyAccount = f.auth.account({ issuer: 'synthetic', subject: 'legacy' }), legacy = f.auth.issue(legacyAccount);
  for (const change of [() => { f.config.ownerPairingEnabled = false; }, () => { f.config.adminPassword += '-changed'; }]) {
    f.config.ownerPairingEnabled = true;
    const token = f.owner.exchange(exchange(f.decide(f.begin()).grant));
    const request = f.owner.start(input()), grant = f.decide(f.begin()).grant;
    change();
    assert.throws(() => f.auth.authenticate(token.access_token));
    assert.throws(() => f.auth.refresh(token.refresh_token));
    assert.throws(() => f.owner.exchange(exchange(grant)));
    f.config.ownerPairingEnabled = true;
    assert.throws(() => f.owner.browser(request));
    assert.throws(() => f.auth.authenticate(token.access_token));
    assert.equal(f.auth.authenticate(legacy.access_token).account, legacyAccount);
  }
}));

test('owner secrets hashed on disk, reboot persistence, password restart invalidates owner only', async () => {
  const dir = await mkdtemp(join(tmpdir(), 'pony-owner-persistence-')), file = join(dir, 'sessions.sqlite');
  let auth;
  try {
    const config = settings(); let now = 1000000;
    auth = new NativeAuth(file, { clock: () => now });
    let owner = new OwnerPairing(auth, config, { clock: () => now });
    const request = owner.start(input()), flow = owner.browser(request);
    const grant = owner.decide({ intent: flow.intent, csrf: flow.csrf, decision: 'approve', verification_code: code }, flow.browser).grant;
    const tokens = owner.exchange(exchange(grant));
    const rotated = auth.refresh(tokens.refresh_token);
    auth.close(); auth = null;
    const raw = await readFile(file);
    for (const secret of [code, config.adminPassword, request, flow.browser, flow.csrf, flow.intent, grant, tokens.access_token, tokens.refresh_token, rotated.access_token]) {
      assert.equal(raw.includes(Buffer.from(secret)), false);
    }
    auth = new NativeAuth(file, { clock: () => now }); owner = new OwnerPairing(auth, config, { clock: () => now });
    assert.equal(auth.authenticate(rotated.access_token).principal_type, 'service_owner');
    assert.throws(() => auth.refresh(tokens.refresh_token));
    assert.throws(() => auth.authenticate(rotated.access_token));
    const other = owner.browser(owner.start(input()));
    const pending = owner.decide({ intent: other.intent, csrf: other.csrf, decision: 'approve', verification_code: code }, other.browser).grant;
    auth.close(); auth = null;
    config.adminPassword += '-rotated';
    auth = new NativeAuth(file, { clock: () => now }); owner = new OwnerPairing(auth, config, { clock: () => now });
    assert.throws(() => owner.exchange(exchange(pending)));
  } finally { auth?.close(); await rm(dir, { recursive: true, force: true }); }
});

async function httpFixture(action, overrides = {}) {
  const dir = await mkdtemp(join(tmpdir(), 'pony-owner-http-'));
  const config = { ...settings(), dir, ...overrides };
  let lists = 0, probes = 0, closed = 0, releaseList = null;
  const vin = 'LRW3E7FA0NC123456', snapshots = new Map();
  const client = { vehicles: async () => { lists++; if (releaseList) await releaseList; return [{ vin }]; },
    probe: async selected => { probes++; return { vehicle: { vin: selected }, data: { synthetic: true } }; } };
  const history = { close: () => { closed++; }, prune() {}, saveProbe: value => snapshots.set(vin, value), snapshot: selected => snapshots.get(selected) };
  const vault = { read: async () => ({ access_token: 'synthetic-legacy-sentinel' }) };
  const server = createApp(config, client, vault, history);
  await new Promise(resolve => server.listen(0, '127.0.0.1', resolve));
  const base = `http://127.0.0.1:${server.address().port}`;
  const basic = `Basic ${Buffer.from(`owner:${config.adminPassword}`).toString('base64')}`;
  const request = (path, options = {}) => fetch(base + path, { redirect: 'manual', ...options });
  const post = (path, value, headers = {}) => request(`/api/native/v1${path}`, { method: 'POST', headers: { 'content-type': 'application/json', ...headers }, body: JSON.stringify(value) });
  const browser = (path, options = {}) => request(path, { ...options, headers: { authorization: basic, ...options.headers } });
  const fields = html => Object.fromEntries([...html.matchAll(/<input type="hidden" name="([^"]+)" value="([^"]*)">/g)].map(m => [m[1], m[2]]));
  async function begin() {
    const started = await post('/pair/start', input()); assert.equal(started.status, 200);
    const value = await started.json(); assert.equal(value.expires_in, 600);
    const url = new URL(value.authorization_url); assert.equal(url.origin, config.origin); assert.equal(url.pathname, '/owner/devices/pair');
    assert.equal(value.authorization_url.includes(code), false);
    const path = url.pathname + url.search, response = await browser(path), html = await response.text();
    assert.equal(response.status, 200); assert.equal(response.headers.get('referrer-policy'), 'same-origin');
    assert.equal(html.includes(code), false); assert.ok(html.includes(config.origin));
    return { path, fields: fields(html), cookie: response.headers.get('set-cookie').split(';')[0], response, html };
  }
  const approve = async (flow, extra = {}, headers = {}) => browser('/owner/devices/pair', { method: 'POST', headers: { origin: config.origin,
    cookie: flow.cookie, 'content-type': 'application/x-www-form-urlencoded', ...headers }, body: new URLSearchParams({ ...flow.fields, decision: 'approve', verification_code: code, ...extra }) });
  async function login() {
    const flow = await begin(), approved = await approve(flow); assert.equal(approved.status, 303);
    assert.equal(approved.headers.get('referrer-policy'), 'no-referrer');
    const callback = new URL(approved.headers.get('location')); assert.equal(callback.origin, 'null');
    assert.equal(`${callback.protocol}//${callback.host}`, CALLBACK);
    const redeemed = await post('/pair/exchange', exchange(callback.searchParams.get('grant'))); assert.equal(redeemed.status, 200);
    return redeemed.json();
  }
  try { await action({ config, request, browser, post, begin, approve, login, fields, basic, vin,
    counters: () => ({ lists, probes, closed }), waitList: promise => { releaseList = promise; } }); }
  finally { server.closeAllConnections(); await new Promise(resolve => server.close(resolve)); assert.equal(closed, 0, 'native cleanup must not close shared history'); await rm(dir, { recursive: true, force: true }); }
}

test('owner browser Basic, exactOrigin, bound CSRF and overlap; no GET approval, denial callback exact keys', async () => httpFixture(async f => {
  const anonymous = await f.request('/owner/devices');
  assert.equal(anonymous.status, 401); assert.ok(anonymous.headers.get('www-authenticate')?.startsWith('Basic '));
  const wrongBasic = await f.request('/owner/devices', { headers: { authorization: 'Basic d3Jvbmc6d3Jvbmc=' } });
  assert.equal(wrongBasic.status, 401); assert.ok(wrongBasic.headers.get('www-authenticate')?.startsWith('Basic '));
  const a = await f.begin(), b = await f.begin();
  assert.equal((await f.browser(a.path)).status, 401);
  assert.ok(a.response.headers.get('set-cookie').includes('Path=/owner/devices'));
  assert.ok(a.response.headers.get('set-cookie').includes('SameSite=Strict'));
  const pairingCSP = a.response.headers.get('content-security-policy');
  assert.ok(pairingCSP.includes(`form-action 'self' ${CALLBACK};`));
  assert.equal(pairingCSP.includes('*'), false);
  assert.equal(pairingCSP.includes('form-action pony-native:'), false);
  for (const directive of ["default-src 'none'", "frame-ancestors 'none'", "base-uri 'none'"]) assert.ok(pairingCSP.includes(directive));
  assert.equal((await f.approve(a, {}, { origin: 'null' })).status, 403);
  assert.equal((await f.approve(a, {}, { origin: 'https://evil.invalid' })).status, 403);
  assert.equal((await f.approve(a, {}, { origin: '' })).status, 403);
  const missingOrigin = await f.browser('/owner/devices/pair', { method: 'POST', headers: {
    cookie: a.cookie, 'content-type': 'application/x-www-form-urlencoded' }, body: new URLSearchParams({ ...a.fields, decision: 'approve', verification_code: code }) });
  assert.equal(missingOrigin.status, 403);
  assert.equal((await f.approve(a, {}, { cookie: b.cookie })).status, 401);
  assert.equal((await f.approve(a, { csrf: b.fields.csrf })).status, 401);
  const denied = await f.approve(a, { decision: 'deny', verification_code: '' });
  assert.equal(denied.status, 303);
  const callback = new URL(denied.headers.get('location'));
  assert.deepEqual([...callback.searchParams.keys()].sort(), ['error', 'state']);
  assert.equal(callback.searchParams.get('error'), 'pairing_rejected'); assert.equal(callback.searchParams.get('state'), input().state);
  assert.equal((await f.approve(a)).status, 401);
  const badForm = await f.browser('/owner/devices/pair', { method: 'POST', headers: { origin: f.config.origin, cookie: b.cookie,
    'content-type': 'application/x-www-form-urlencoded' }, body: `intent=${b.fields.intent}&csrf=${b.fields.csrf}&decision=approve&decision=deny&verification_code=${code}` });
  assert.equal(badForm.status, 401);
  const mismatch = await f.approve(b, { verification_code: 'BAD0C0DE' });
  assert.equal(mismatch.status, 401);
  const retryHTML = await mismatch.text();
  assert.equal(mismatch.headers.get('referrer-policy'), 'same-origin');
  assert.ok(retryHTML.includes('核对码不匹配'));
  assert.deepEqual(f.fields(retryHTML), b.fields);
  assert.equal(retryHTML.includes('BAD0C0DE'), false); assert.equal(retryHTML.includes(code), false);
  assert.ok(retryHTML.includes('formnovalidate'));
  assert.equal((await f.approve(b, { decision: 'deny', verification_code: 'nothex' })).status, 303);
  assert.equal((await f.post('/pair/start', { ...input(), extra: true })).status, 401);
  assert.equal((await f.post('/pair/start', { padding: 'x'.repeat(5000) })).status, 413);
}));

test('owner session and admin management separation; list truthful, revoke session and old enrollments', async () => httpFixture(async f => {
  const paired = await f.login(), bearer = { authorization: `Bearer ${paired.access_token}` };
  assert.equal(f.counters().lists, 0); assert.equal(f.counters().probes, 0);
  const session = await (await f.request('/api/native/v1/session', { headers: bearer })).json();
  assert.equal(session.principal_type, 'service_owner'); assert.equal(session.features.trips, false);
  assert.equal((await f.request('/owner/devices', { headers: bearer })).status, 401);
  assert.equal((await f.request('/api/native/v1/vehicles')).status, 401);
  assert.equal((await f.request('/api/native/v1/history', { headers: bearer })).status, 404);
  const old = await f.begin();
  const page = await f.browser('/owner/devices'), html = await page.text();
  assert.equal(page.headers.get('referrer-policy'), 'same-origin');
  const managementCSP = page.headers.get('content-security-policy');
  assert.ok(managementCSP.includes("form-action 'self';"));
  assert.equal(managementCSP.includes(CALLBACK), false);
  assert.ok(html.includes('已领取连接凭据')); assert.equal(html.includes(paired.access_token), false);
  const fields = f.fields(html), cookie = page.headers.get('set-cookie').split(';')[0];
  const revoke = headers => f.browser('/owner/devices/revoke', { method: 'POST', headers: { cookie, 'content-type': 'application/x-www-form-urlencoded', ...headers }, body: new URLSearchParams(fields) });
  assert.equal((await revoke({})).status, 403);
  assert.equal((await revoke({ origin: f.config.origin })).status, 303);
  assert.equal((await f.request('/api/native/v1/session', { headers: bearer })).status, 401);
  assert.equal((await f.post('/auth/refresh', { refresh_token: paired.refresh_token })).status, 401);
  assert.equal((await f.approve(old)).status, 401);
}));

test('owner uses legacy singleton and shared admin/native operation budgets without resetting locks', async () => httpFixture(async f => {
  const paired = await f.login(), bearer = { authorization: `Bearer ${paired.access_token}` };
  let release, started;
  const waiting = new Promise(resolve => { release = resolve; });
  // Fetch receives no headers until the synthetic client releases its list.
  f.waitList(waiting);
  const pending = f.browser('/api/vehicles');
  await new Promise((resolve, reject) => {
    const deadline = Date.now() + 5000;
    const check = () => { if (f.counters().lists) { started = true; resolve(); } else if (Date.now() >= deadline) reject(new Error('Synthetic list not started')); else setImmediate(check); }; check();
  });
  try {
    assert.ok(started);
    assert.equal((await f.request('/api/native/v1/vehicles', { headers: bearer })).status, 429);
    assert.equal((await f.post(`/vehicles/${f.vin}/probe`, {}, bearer)).status, 429);
  } finally { release(); f.waitList(null); }
  assert.equal((await pending).status, 200);
  assert.equal((await f.post(`/vehicles/${f.vin}/probe`, {}, bearer)).status, 200);
  assert.equal((await f.browser('/api/probe', { method: 'POST', headers: { origin: f.config.origin, 'content-type': 'application/json' }, body: JSON.stringify({ vin: f.vin }) })).status, 429);
  const snapshot = await f.request(`/api/native/v1/vehicles/${f.vin}/snapshot`, { headers: bearer }); assert.equal(snapshot.status, 200);
  // One admin list + native probe + native snapshot consumed the same30 budget.
  for (let i = 0; i < 27; i++) assert.equal((await f.browser('/api/vehicles')).status, 200);
  assert.equal((await f.request('/api/native/v1/vehicles', { headers: bearer })).status, 429);
  assert.equal((await f.browser('/api/vehicles')).status, 429);
}));

test('owner feature gate defaults off without changing ordinary native availability', async () => httpFixture(async f => {
  assert.equal((await f.post('/pair/start', input())).status, 404);
  assert.equal((await f.browser('/owner/devices')).status, 404);
  assert.equal((await f.browser('/api/status')).status, 200);
}, { ownerPairingEnabled: false }));
