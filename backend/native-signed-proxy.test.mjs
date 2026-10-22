import test from 'node:test';
import assert from 'node:assert/strict';
import { EventEmitter } from 'node:events';
import { rootCertificates } from 'node:tls';
import { SafeError } from './core.mjs';
import { NativeSignedProxy, createNativeSignedProxy, SIGNED_PROXY_COMMANDS } from './native-signed-proxy.mjs';

// Public CA certificate, NOT a private key. No sockets, filesystem, or external services.
const ca = rootCertificates[0];
const vin = '5YJ3E1EA7KF000001';
const token = 'TEST_ONLY_TOKEN_NEVER_RETURNED';
const config = () => ({ enabled: true, port: 4443, ca, deadlineMs: 1000,
  audit: { release: 'test-fixture-not-installed', sourceDigest: `sha256:${'a'.repeat(64)}`,
    officialSourceReviewed: true, retransmissionPolicyReviewed: true } });
const rejected = cause => ({ status: 'rejected', cause, result: false, rejected: true });
const unknown = cause => ({ status: 'unknown', cause });
function harness({ settings = config(), accessToken, behavior } = {}) {
  const calls = [], tokens = [], timers = new Map(); let nextTimer = 0;
  const request = (options, callback) => {
    const req = new EventEmitter(); req.destroyed = false;
    req.destroy = () => { req.destroyed = true; };
    req.end = body => { calls[calls.length - 1].body = body; behavior?.(req, callback); };
    calls.push({ options, req, callback });
    return req;
  };
  const adapter = createNativeSignedProxy(settings, {
    accessToken: account => { tokens.push(account); return accessToken ? accessToken(account) : token; },
    request,
    setTimer: fn => { const id = ++nextTimer; timers.set(id, fn); return id; },
    clearTimer: id => timers.delete(id),
  });
  return { adapter, calls, tokens, timers,
    expire: () => { for (const fn of [...timers.values()]) fn(); } };
}
function respond(callback, status = 200, body = '{"response":{"result":true}}') {
  const res = new EventEmitter(); res.statusCode = status; res.complete = false; res.destroyed = false;
  res.destroy = () => { res.destroyed = true; };
  callback(res);
  if (body !== null) { res.emit('data', Buffer.from(body)); res.complete = true; res.emit('end'); }
  return res;
}
// Advance only the credential Promise chain; never wait on real timers/network.
const flush = async () => { await Promise.resolve(); await Promise.resolve(); await Promise.resolve(); };

test('default disabled; no credential lookup or request; provider required', async () => {
  const h = harness({ settings: {} });
  assert.deepEqual(await h.adapter.sendSigned('native_1', vin, 'door_lock'), rejected('disabled'));
  assert.equal(h.tokens.length, 0); assert.equal(h.calls.length, 0);
  assert.throws(() => createNativeSignedProxy(), SafeError);
  assert.throws(() => new NativeSignedProxy(), SafeError);
});

test('enablement requires explicit pinned review, CA, numeric bounded port, and no host/URL escape hatch', () => {
  const cases = [
    { port: '4443' }, { port: 0 }, { port: 65536 }, { port: NaN }, { port: 1.2 },
    { ca: '' }, { ca: 'not a certificate' }, { ca: undefined },
    { audit: undefined }, { audit: { ...config().audit, retransmissionPolicyReviewed: false } },
    { audit: { ...config().audit, officialSourceReviewed: false } },
    { audit: { ...config().audit, release: '' } },
    { audit: { ...config().audit, release: 'main' } },
    { audit: { ...config().audit, sourceDigest: 'main' } },
    { host: 'evil.test' }, { hostname: '127.0.0.2' }, { url: 'https://evil.test/' },
    { redirect: 'follow' }, { rejectUnauthorized: false }, { servername: 'evil.test' },
    { deadlineMs: 0 }, { deadlineMs: 30001 }, { deadlineMs: '1000' }, { enabled: 'true' },
  ];
  for (const patch of cases) assert.throws(() => harness({ settings: { ...config(), ...patch } }), SafeError);
});

test('one POST uses fixed IPv4 loopback, mandatory TLS trust and localhost identity', async () => {
  const h = harness({ behavior: (_req, cb) => respond(cb) });
  const result = await h.adapter.sendSigned('native_1', vin, 'set_charge_limit', { percent: 80 });
  assert.deepEqual(result, { status: 'accepted', cause: 'proxy_acknowledged', result: true });
  assert.deepEqual(h.tokens, ['native_1']); assert.equal(h.calls.length, 1);
  const { options, body } = h.calls[0];
  assert.equal(options.protocol, 'https:'); assert.equal(options.hostname, '127.0.0.1');
  assert.equal(options.family, 4); assert.equal(options.port, 4443);
  assert.equal(options.servername, 'localhost'); assert.equal(options.ca, ca);
  assert.equal(options.rejectUnauthorized, true); assert.equal(options.agent, false);
  assert.equal(options.method, 'POST');
  assert.equal(options.path, `/api/1/vehicles/${vin}/command/set_charge_limit`);
  assert.equal(options.headers['Content-Type'], 'application/json');
  assert.equal(options.headers.Authorization, `Bearer ${token}`);
  assert.equal(options.headers['Content-Length'], Buffer.byteLength(body));
  assert.equal(body, '{"percent":80}'); assert.equal(Object.hasOwn(options, 'redirect'), false);
  assert.equal(JSON.stringify(result).includes(token), false);
  assert.equal(JSON.stringify(h.adapter).includes(token), false);
  assert.equal(h.timers.size, 0);
});

test('strict command and parameter allowlist rejects before token lookup', async () => {
  const h = harness();
  const bad = [
    ['native_1', vin, 'wake_up', {}], ['native_1', vin, '../door_lock', {}],
    ['native_1', vin, 'toString', {}], ['native_1', vin, 'door_lock?x=1', {}],
    ['', vin, 'door_lock', {}], ['native 1', vin, 'door_lock', {}],
    ['native_1', `${vin}/command/door_lock`, 'door_lock', {}],
    ['native_1', vin.toLowerCase(), 'door_lock', {}],
    ['native_1', vin, 'door_lock', { token }], ['native_1', vin, 'door_lock', []],
    ['native_1', vin, 'door_lock', null],
    ['native_1', vin, 'set_charge_limit', { percent: '80' }],
    ['native_1', vin, 'set_charge_limit', { percent: 49 }],
    ['native_1', vin, 'set_charge_limit', { percent: 101 }],
    ['native_1', vin, 'set_charge_limit', { percent: 80.1 }],
    ['native_1', vin, 'set_temps', { driver_temp: NaN, passenger_temp: 20 }],
    ['native_1', vin, 'set_temps', { driver_temp: 20, passenger_temp: Infinity }],
    ['native_1', vin, 'set_temps', { driver_temp: 14, passenger_temp: 20 }],
    ['native_1', vin, 'set_temps', { driver_temp: 20 }],
    ['native_1', vin, 'set_sentry_mode', { on: 1 }],
    ['native_1', vin, 'actuate_trunk', { which_trunk: 'both' }],
    ['native_1', vin, 'window_control', { command: 'open' }],
    ['native_1', vin, 'remote_seat_heater_request', { heater: 2, level: 1 }],
    ['native_1', vin, 'remote_seat_heater_request', { heater: 3, level: 1 }],
    ['native_1', vin, 'remote_seat_heater_request', { heater: 4, level: 1 }],
    ['native_1', vin, 'remote_seat_heater_request', { heater: 5, level: 1 }],
    ['native_1', vin, 'set_climate_keeper_mode', { climate_keeper_mode: 4 }],
    ['native_1', vin, 'door_lock', { [Symbol('extra')]: true }],
    ['native_1', vin, 'set_sentry_mode', Object.defineProperty({}, 'on', { get() { throw Error(token); } })],
  ];
  for (const args of bad) assert.deepEqual(await h.adapter.sendSigned(...args), rejected('invalid_request'));
  assert.equal(h.tokens.length, 0); assert.equal(h.calls.length, 0);
});

test('every allowlisted Fleet endpoint has well-typed bounded arguments', async () => {
  const params = {
    actuate_trunk: { which_trunk: 'front' }, set_sentry_mode: { on: true },
    window_control: { command: 'close' }, set_charge_limit: { percent: 50 },
    set_temps: { driver_temp: 15, passenger_temp: 28 },
    set_climate_keeper_mode: { climate_keeper_mode: 3 }, set_preconditioning_max: { on: false },
    remote_seat_heater_request: { heater: 1, level: 3 }, remote_steering_wheel_heater_request: { on: true },
  };
  const h = harness({ behavior: (_req, cb) => respond(cb) });
  assert.equal(SIGNED_PROXY_COMMANDS.length, 19);
  for (const command of SIGNED_PROXY_COMMANDS) {
    assert.equal((await h.adapter.sendSigned('native_1', vin, command, params[command] ?? {})).status, 'accepted');
  }
  assert.equal(h.calls.length, SIGNED_PROXY_COMMANDS.length);
});

test('credential errors and invalid tokens are sanitized, never forwarded', async () => {
  for (const accessToken of [() => { throw Error(token); }, () => Promise.reject(Error(token)),
    () => '', () => `bad\r\nAuthorization: ${token}`, () => ({ access_token: token })]) {
    const h = harness({ accessToken });
    assert.deepEqual(await h.adapter.sendSigned('native_1', vin, 'door_lock'), rejected('token_unavailable'));
    assert.equal(h.calls.length, 0);
  }
});

test('redirects/non-200 never follow or resend and never expose upstream bodies', async () => {
  for (const status of [301, 302, 307, 308, 401, 403, 421, 429, 500]) {
    let res;
    const h = harness({ behavior: (_req, cb) => { res = respond(cb, status, token); } });
    assert.deepEqual(await h.adapter.sendSigned('native_1', vin, 'door_lock'), unknown('http_status'));
    assert.equal(h.calls.length, 1); assert.equal(res.destroyed, true); assert.equal(h.calls[0].req.destroyed, true);
  }
});

test('malformed and negative replies are ambiguous, not proof of non-execution', async () => {
  for (const body of [token, '{}', 'null', '{"response":{"result":"true"}}',
    '{"response":{"result":false,"reason":"' + token + '"}}']) {
    const h = harness({ behavior: (_req, cb) => respond(cb, 200, body) });
    const result = await h.adapter.sendSigned('native_1', vin, 'door_lock');
    assert.equal(result.status, 'unknown'); assert.equal(result.result, undefined);
    assert.equal(JSON.stringify(result).includes(token), false); assert.equal(h.calls.length, 1);
  }
});

test('response cap includes all chunks; overflow destroys both streams with no resend', async () => {
  let res;
  const h = harness({ behavior: (_req, cb) => {
    res = respond(cb, 200, null);
    res.emit('data', Buffer.alloc(8192)); res.emit('data', Buffer.alloc(8193));
    res.emit('end');
  } });
  assert.deepEqual(await h.adapter.sendSigned('native_1', vin, 'door_lock'), unknown('response_too_large'));
  assert.equal(res.destroyed, true); assert.equal(h.calls[0].req.destroyed, true); assert.equal(h.calls.length, 1);
});

test('exactly 16KiB is within the response cap', async () => {
  const body = '{"response":{"result":true}}';
  const h = harness({ behavior: (_req, cb) => respond(cb, 200, body.padEnd(16384)) });
  assert.equal((await h.adapter.sendSigned('native_1', vin, 'door_lock')).status, 'accepted');
});

test('request factory throws are ambiguous with no header or raw Error leakage', async () => {
  let attempts = 0;
  const adapter = new NativeSignedProxy(config(), {
    accessToken: () => token,
    request: () => { attempts++; throw Error(`Authorization: Bearer ${token}`); },
    setTimer: () => 1, clearTimer: () => {},
  });
  assert.deepEqual(await adapter.sendSigned('native_1', vin, 'door_lock'), unknown('transport_error'));
  assert.equal(attempts, 1);
});

test('request throw, transport error, timeout and abort are sanitized and never resend', async () => {
  for (const event of ['throw', 'error', 'timeout', 'abort', 'close']) {
    const h = harness({ behavior: req => {
      if (event === 'throw') throw Error(token);
      req.emit(event, Error(token));
    } });
    const result = await h.adapter.sendSigned('native_1', vin, 'door_lock');
    assert.equal(result.status, 'unknown'); assert.equal(JSON.stringify(result).includes(token), false);
    assert.equal(h.calls.length, 1); assert.equal(h.calls[0].req.destroyed, true);
  }
});

test('response error, abort and premature close are ambiguous', async () => {
  for (const event of ['error', 'aborted', 'close']) {
    const h = harness({ behavior: (_req, cb) => respond(cb, 200, null).emit(event, Error(token)) });
    assert.equal((await h.adapter.sendSigned('native_1', vin, 'door_lock')).status, 'unknown');
    assert.equal(h.calls.length, 1);
  }
});

test('deadline covers connect and incomplete response; late events cannot resend or change result', async () => {
  for (const receiving of [false, true]) {
    let res;
    const h = harness({ behavior: (_req, cb) => { if (receiving) res = respond(cb, 200, null); } });
    const pending = h.adapter.sendSigned('native_1', vin, 'door_lock');
    await flush(); assert.equal(h.calls.length, 1);
    h.expire(); assert.deepEqual(await pending, unknown('deadline'));
    assert.equal(h.calls[0].req.destroyed, true);
    if (res) { assert.equal(res.destroyed, true); res.emit('end'); }
    h.calls[0].req.emit('error', Error(token));
    assert.equal(h.calls.length, 1); assert.equal(h.timers.size, 0);
  }
});

test('deadline during token lookup never dispatches after late token resolution', async () => {
  let release;
  const h = harness({ accessToken: () => new Promise(resolve => { release = resolve; }) });
  const pending = h.adapter.sendSigned('native_1', vin, 'door_lock');
  await flush(); h.expire(); assert.deepEqual(await pending, unknown('deadline'));
  release(token); await flush(); assert.equal(h.calls.length, 0);
});
