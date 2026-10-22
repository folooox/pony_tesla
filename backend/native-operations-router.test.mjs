import test from 'node:test';
import assert from 'node:assert/strict';
import { createServer } from 'node:http';
import { mkdtemp, rm, realpath } from 'node:fs/promises';
import { tmpdir } from 'node:os';
import { join } from 'node:path';
import { createNativeRouter } from './native-router.mjs';
import { createNativeOperationsRouter } from './native-operations-router.mjs';
import { NativeAuth, CALLBACK, hash } from './native-auth.mjs';
import { NativeCaptureStore } from './native-capture.mjs';
import { CommandStore, CommandService } from './native-commands.mjs';

const vin = 'LRW3E7FA0NC123456', otherVin = 'LRW3E7FA0NC123457';
const action = { command: 'door_lock', params: {} };
async function fixture(run, { enabled = true, ready = true } = {}) {
  // macOS tmpdir() is commonly /var -> /private/var; use the canonical private path.
  const dir = await realpath(await mkdtemp(join(tmpdir(), 'pony-operations-')));
  let now = Date.parse('2026-10-19T12:00:00Z'), lists = 0, sends = 0, checks = 0, probes = 0, listWait;
  const auth = new NativeAuth(join(dir, 'auth.sqlite'), { clock: () => now });
  // Trusted leaf identity setup only. Public requests still redeem a real NativeAuth PKCE grant.
  const accounts = ['A', 'B'].map(subject => auth.account({ issuer: 'fixture-verified-issuer', subject }));
  const membership = new Map(accounts.map(id => [id, [vin, otherVin]]));
  const operator = Object.freeze({}), receiver = Object.freeze({});
  const captures = new Map(), commands = new Map(), contexts = new Map();
  const router = createNativeRouter({ nativeEnabled: true, origin: 'https://fixture.invalid', nativeApprovedOrigin: 'https://fixture.invalid', missing: [], key: 'b'.repeat(64) }, {
    auth, clock: () => now, transport: () => { throw new Error('External transport forbidden'); },
    accountFactory: id => {
      const context = { client: { vehicles: async () => { lists++; if (listWait && id === accounts[0]) await listWait; return membership.get(id).map(vin => ({ vin })); }, probe: async () => { probes++; throw new Error('No probe expected'); } }, history: { close() {} } };
      contexts.set(id, context); return context;
    },
    ...(enabled ? { operationsFactory: (id, { authenticateAccount }) => {
      const capture = new NativeCaptureStore(join(dir, `${id}-capture.sqlite`), { clock: () => now, authenticateAccount,
        authorizeOperator: value => value === operator,
        authenticateReceiver: value => value === receiver ? { vin, stream: id } : null });
      captures.set(id, capture);
      const store = new CommandStore(join(dir, `${id}-commands.sqlite`), { clock: () => now });
      const service = new CommandService({ store, enabled: true, clock: () => now,
        checkAuthorization: async (account, selected) => { checks++; return { account, vin: selected, member: membership.get(account).includes(selected), keyPaired: true, online: true, supported: ['door_lock'], scopes: ['vehicle_cmds'], checkedAt: now }; },
        sendSigned: async (account, selected, command, params) => { assert.ok(accounts.includes(account)); assert.equal(selected, vin); assert.equal(command, 'door_lock'); assert.deepEqual(params, {}); sends++; return { result: true }; } });
      commands.set(id, service);
      return { capture, commands: service, ready: { history: ready, commands: ready } };
    } } : {}),
  });
  const server = createServer(async (req, res) => {
    if (!await router(req, res, new URL(req.url, 'http://localhost'))) { res.writeHead(404); res.end(); }
  });
  await new Promise(resolve => server.listen(0, '127.0.0.1', resolve));
  const base = `http://127.0.0.1:${server.address().port}/api/native/v1`;
  const request = (path, token, method = 'GET', body, headers = {}) => fetch(base + path, { method,
    headers: { ...(token ? { authorization: `Bearer ${token}` } : {}), ...(body !== undefined ? { 'content-type': 'application/json' } : {}), ...headers },
    ...(body !== undefined ? { body: JSON.stringify(body) } : {}) });
  async function login(index) {
    const verifier = 'v'.repeat(43), grant = auth.grant(accounts[index], { code_challenge: hash(verifier) });
    const response = await request('/auth/exchange', null, 'POST', { grant, code_verifier: verifier, callback: CALLBACK });
    assert.equal(response.status, 200); return (await response.json()).access_token;
  }
  const a = await login(0), b = await login(1);
  async function seed(index) {
    const response = await request('/session', index ? b : a);
    assert.equal(response.status, 200, await response.clone().text());
    const capture = captures.get(accounts[index]);
    const binding = capture.register(operator, { account: accounts[index], vin, stream: accounts[index], expires_at: new Date(now + 60000).toISOString() });
    capture.ingest(receiver, binding.binding_id, [
      { id: 'park', kind: 'trip', at: new Date(now - 3000).toISOString(), gear: 'P' },
      { id: 'drive', kind: 'trip', at: new Date(now - 2000).toISOString(), gear: 'D', odometer_km: 10 },
      { id: 'end', kind: 'trip', at: new Date(now - 1000).toISOString(), gear: 'P', odometer_km: 11 },
    ]);
    return (await (await request(`/vehicles/${vin}/history?kind=trip&limit=30`, index ? b : a)).json()).records[0].id;
  }
  try { await run({ request, a, b, accounts, membership, captures, commands, contexts, seed,
    advance: ms => { now += ms; }, counters: () => ({ lists, sends, checks, probes }), setWait: value => { listWait = value; } }); }
  finally {
    server.closeAllConnections(); await new Promise(resolve => server.close(resolve)); router.close();
    for (const c of captures.values()) c.close(); for (const c of commands.values()) c.store.close();
    await rm(dir, { recursive: true, force: true });
  }
}

test('optional routes default off and readiness requires explicit verified dependencies', async () => {
  for (const options of [{ enabled: false }, { ready: false }]) await fixture(async f => {
    const response = await f.request('/session', f.a);
    assert.equal(response.status, 200, await response.clone().text());
    const session = await response.json();
    for (const flag of ['commands', 'telemetry', 'trips', 'charge_history']) assert.equal(session.features[flag], false);
    assert.equal((await f.request(`/vehicles/${vin}/history`, f.a)).status, 404);
    assert.equal((await f.request(`/vehicles/${vin}/commands/context`, f.a, 'POST', {})).status, 404);
    assert.deepEqual(f.counters(), { lists: 0, sends: 0, checks: 0, probes: 0 });
  }, options);
});

test('real capture history isolates account/VIN, requires fresh membership for detail/delete/export', async () => fixture(async f => {
  const id = await f.seed(0), bid = await f.seed(1);
  const session = await (await f.request('/session', f.a)).json();
  assert.equal(session.features.telemetry, false); assert.equal(session.features.trips, true); assert.equal(session.features.commands, true);
  assert.notEqual(id, bid);
  assert.equal((await f.request(`/vehicles/${vin}/history/${id}`, f.b)).status, 404);
  assert.equal((await f.request(`/vehicles/${otherVin}/history/${id}`, f.a)).status, 404);
  const annotated = await f.request(`/vehicles/${vin}/history/${id}`, f.a, 'PATCH', { tag: '=tag', note: 'private A' });
  assert.equal(annotated.status, 200);
  const csv = await f.request(`/vehicles/${vin}/history/${id}/export.csv`, f.a);
  assert.equal(csv.status, 200); assert.equal(csv.headers.get('cache-control'), 'no-store');
  assert.equal(csv.headers.get('x-content-type-options'), 'nosniff');
  assert.equal(csv.headers.get('content-disposition'), 'attachment; filename="pony-history.csv"');
  assert.ok((await csv.text()).includes("'=tag"));
  f.membership.set(f.accounts[0], []);
  for (const [suffix, method, body] of [['', 'GET'], [`/${id}`, 'GET'], [`/${id}`, 'PATCH', { tag: '', note: '' }], [`/${id}`, 'DELETE', { confirm: true }], ['', 'DELETE', { confirm: true }], [`/${id}/export.csv`, 'GET']]) {
    assert.equal((await f.request(`/vehicles/${vin}/history${suffix}`, f.a, method, body)).status, 403);
  }
  assert.equal((await f.request(`/vehicles/${vin}/history/${bid}`, f.b)).status, 200);
  assert.equal((await f.request(`/vehicles/${vin}/history/${bid}`, f.b, 'DELETE', { confirm: true })).status, 200);
  assert.equal((await f.request(`/vehicles/${vin}/history/${bid}`, f.b)).status, 404);
}));

test('query/body/auth validation precedes Fleet; no caller account or readback accepted', async () => fixture(async f => {
  for (const query of ['?account_id=A', '?kind=trip&kind=charge', '?kind=fake', '?limit=0', '?limit=1e1', '?before=garbage']) assert.equal((await f.request(`/vehicles/${vin}/history${query}`, f.a)).status, 400);
  for (const headers of [{ authorization: 'Basic Zm9vOmJhcg==' }, { authorization: 'Bearer bad' }, {}]) assert.equal((await f.request(`/vehicles/${vin}/history`, null, 'GET', undefined, headers)).status, 401);
  assert.equal((await f.request(`/vehicles/${vin}/history`, f.a, 'DELETE', { confirm: true, account: 'A' })).status, 400);
  assert.equal((await f.request(`/vehicles/${vin}/history`, f.a, 'DELETE', { confirm: false })).status, 400);
  assert.equal((await f.request(`/vehicles/${vin}/commands/context`, f.a, 'POST', {}, { 'content-type': 'text/plain' })).status, 415);
  assert.equal((await f.request(`/vehicles/${vin}/commands/context`, f.a, 'POST', { padding: 'x'.repeat(5000) })).status, 413);
  for (const path of ['', '/', '/unknown', '/telemetry', '/operator/register']) assert.equal((await f.request(path, f.a)).status, 404);
  assert.equal(f.counters().lists, 0);
}));

test('family/VIN-bound explicit context rotation prevents stale/replayed selection; status never auto-readbacks', async () => fixture(async f => {
  const selection = await f.request(`/vehicles/${vin}/commands/context`, f.a, 'POST', {});
  assert.equal(selection.status, 200, await selection.clone().text());
  const context = (await selection.json()).context;
  const prepared = await f.request(`/vehicles/${vin}/commands/prepare`, f.a, 'POST', { action, context });
  assert.equal(prepared.status, 200); const intent = await prepared.json();
  const execute = { action, context, intentId: intent.intentId, requestId: intent.requestId };
  assert.equal((await f.request('/commands/execute', f.b, 'POST', execute)).status, 409);
  assert.equal((await f.request('/commands/execute', f.a, 'POST', execute)).status, 200);
  assert.equal((await f.request('/commands/execute', f.a, 'POST', execute)).status, 200);
  assert.equal(f.counters().sends, 1);
  const checks = f.counters().checks;
  assert.equal((await f.request(`/commands/${intent.requestId}`, f.a)).status, 200);
  assert.equal(f.counters().checks, checks);
  assert.equal((await f.request(`/commands/${intent.requestId}/confirm`, f.a, 'POST', { context, readback: { authentic: true } })).status, 400);
  const unprovenConfirmation = await f.request(`/commands/${intent.requestId}/confirm`, f.a, 'POST', { context });
  assert.equal(unprovenConfirmation.status, 200);
  assert.equal((await unprovenConfirmation.json()).status, 'awaiting_readback');
  // Neither HTTP acceptance nor a caller's explicit readback request proves that
  // the old sender/proxy is quiescent. No authority is installed in this fixture.
  assert.equal(f.counters().checks, checks);
  assert.equal(f.counters().sends, 1);
  const blockedIntentReply = await f.request(`/vehicles/${vin}/commands/prepare`, f.a, 'POST', { action, context });
  assert.equal(blockedIntentReply.status, 200);
  const blockedIntent = await blockedIntentReply.json();
  assert.equal((await f.request('/commands/execute', f.a, 'POST', {
    action, context, intentId: blockedIntent.intentId, requestId: blockedIntent.requestId
  })).status, 409);
  assert.equal(f.counters().sends, 1);
  f.membership.set(f.accounts[0], []);
  assert.equal((await f.request(`/commands/${intent.requestId}`, f.a)).status, 403);
  assert.equal((await f.request(`/commands/${intent.requestId}/confirm`, f.a, 'POST', { context })).status, 403);
  assert.equal((await f.request(`/vehicles/${vin}/commands/prepare`, f.a, 'POST', { context, action })).status, 403);
  assert.equal((await f.request('/commands/execute', f.a, 'POST', execute)).status, 403);
  f.membership.set(f.accounts[0], [vin, otherVin]);
  const changed = await f.request(`/vehicles/${otherVin}/commands/context`, f.a, 'POST', {}); assert.equal(changed.status, 200);
  assert.equal((await f.request('/commands/execute', f.a, 'POST', execute)).status, 409);
  assert.equal((await f.request(`/commands/${intent.requestId}`, f.a)).status, 404);
  assert.equal((await f.request('/auth/logout', f.a, 'POST', {})).status, 200);
  assert.equal((await f.request('/commands/execute', f.a, 'POST', execute)).status, 401);
}));

test('operations share account Fleet admission with readonly list and snapshot', async () => fixture(async f => {
  await f.request('/session', f.a);
  let release; f.setWait(new Promise(resolve => { release = resolve; }));
  const pending = f.request(`/vehicles/${vin}/history`, f.a);
  await new Promise((resolve, reject) => {
    const deadline = Date.now() + 5000;
    function check() { if (f.contexts.get(f.accounts[0])?.fleetActive) resolve(); else if (Date.now() > deadline) reject(new Error('No admission lock')); else setImmediate(check); } check();
  });
  try {
    assert.equal((await f.request('/vehicles', f.a)).status, 429);
    assert.equal((await f.request(`/vehicles/${vin}/snapshot`, f.a)).status, 429);
    assert.equal((await f.request(`/vehicles/${vin}/history`, f.b)).status, 200);
  } finally { release(); f.setWait(null); }
  assert.equal((await pending).status, 200);
  f.advance(60000);
  for (let i = 0; i < 30; i++) assert.equal((await f.request(`/vehicles/${vin}/history`, f.a)).status, 200);
  assert.equal((await f.request('/vehicles', f.a)).status, 429);
  assert.equal((await f.request(`/vehicles/${vin}/history`, f.a)).status, 429);
}));

test('leaf selection capacity recovers after expiry; backwards clock invalidates without extending authority', async () => {
  let now = 10000, invalidations = 0;
  const commands = { ready() {}, prepare() {}, execute() {}, status() {}, confirm() {},
    store: { invalidateContext(account, context) { assert.equal(account, 'fixture-account'); assert.match(context, /^[A-Za-z0-9_-]{43}$/); invalidations++; } } };
  const ops = { commands, ready: { commands: true } };
  const leaf = createNativeOperationsRouter({ factory: () => ops, clock: () => now,
    readBody: () => { throw new Error('Unit test must not bypass public body validation'); } });
  async function select(family) {
    const session = { account: 'fixture-account', family }, route = { type: 'context', vin };
    const dependencies = leaf.resolve(session, route);
    let output;
    await leaf.handle({}, {}, route, session, dependencies, () => session, value => { output = value; });
    return output;
  }
  for (let i = 0; i < 1000; i++) await select(`family-${i}`);
  await assert.rejects(select('over-capacity'), error => error.status === 429);
  assert.equal(invalidations, 0);
  now += 3600_000;
  const renewed = await select('new-family');
  assert.match(renewed.context, /^[A-Za-z0-9_-]{43}$/);
  assert.equal(invalidations, 1000);
  assert.throws(() => leaf.resolve({ account: 'fixture-account', family: 'family-0' }, { type: 'status', id: 'unused' }), error => error.status === 409);
  now--;
  assert.throws(() => leaf.resolve({ account: 'fixture-account', family: 'new-family' }, { type: 'status', id: 'unused' }), error => error.status === 409);
  assert.equal(invalidations, 1001);
  await select('after-clock-rollback');
});
