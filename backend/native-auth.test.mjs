import test from 'node:test';
import assert from 'node:assert/strict';
import { generateKeyPairSync, sign } from 'node:crypto';
import { DatabaseSync } from 'node:sqlite';
import { mkdtemp, rm, stat, readFile } from 'node:fs/promises';
import { tmpdir } from 'node:os';
import { join } from 'node:path';
import { NativeAuth, IdentityVerifier, CALLBACK, JWKS, GLOBAL_JWKS, hash, REFRESH_MS, AUTH_REASON } from './native-auth.mjs';
import { AUTH } from './core.mjs';

// Synthetic RSA fixture, generated locally; never network or real Tesla identities.
const rsa = generateKeyPairSync('rsa', { modulusLength: 2048 });
const other = generateKeyPairSync('rsa', { modulusLength: 2048 });
const jwk = { ...rsa.publicKey.export({ format: 'jwk' }), kid: 'fixture-key', alg: 'RS256', use: 'sig' };
const now = Date.parse('2026-10-18T12:00:00Z');
const claims = nonce => ({ iss: AUTH, sub: 'synthetic-subject-A', aud: 'fixture-client', nonce, iat: now / 1000, exp: now / 1000 + 3600 });
function jwt(payload, header = { alg: 'RS256', kid: jwk.kid }, key = rsa.privateKey) {
  const value = [header, payload].map(x => Buffer.from(JSON.stringify(x)).toString('base64url')).join('.');
  return `${value}.${sign('RSA-SHA256', Buffer.from(value), key).toString('base64url')}`;
}
const verifier = options => new IdentityVerifier('fixture-client', { clock: () => now,
  transport: async url => { assert.equal(url, JWKS); return new Response(JSON.stringify({ keys: [jwk] })); }, ...options });
const start = (auth, extra = {}) => auth.start({ code_challenge: hash('v'.repeat(43)), callback: CALLBACK, state: 'fixture_state_123456', ...extra });
function grant(auth, subject = 'A') {
  const pending = auth.browser(start(auth));
  const data = auth.consumeState(pending.state, pending.browser);
  const account = auth.account({ issuer: AUTH, subject });
  return { grant: auth.grant(account, data), code_verifier: 'v'.repeat(43), callback: CALLBACK, account };
}

test('RS256 verifies fixed China issuer/audience/nonce and stable public subject only', async () => {
  const value = await verifier().verify(jwt({ ...claims('nonce'), unknown_future_claim: { email: 'ignored' } }), 'nonce');
  assert.deepEqual(value, { issuer: AUTH, subject: 'synthetic-subject-A' });
  await verifier().verify(jwt({ ...claims('nonce'), aud: ['fixture-client', 'another'], azp: 'fixture-client' }), 'nonce');
});

test('identity rejects invalid signature, token structure, alg/kid/URLs, issuer/aud/azp, nonce and times', async t => {
  const base = claims('nonce');
  const invalidClaims = [
    { iss: 'https://auth.tesla.com/oauth2/v3' }, { aud: 'wrong' }, { aud: ['fixture-client', 'other'] },
    { aud: ['fixture-client', 'other'], azp: 'wrong' }, { azp: 'wrong' }, { aud: 123 },
    { sub: '' }, { sub: '   ' }, { sub: null }, { nonce: 'wrong' }, { nonce: undefined },
    { exp: now / 1000 }, { exp: undefined }, { exp: '9999999999' }, { iat: now / 1000 + 31 },
    { iat: now / 1000 - 3601 }, { iat: undefined }, { exp: now / 1000 + 86401 }, { nbf: now / 1000 + 1 },
  ];
  for (const patch of invalidClaims) await t.test(JSON.stringify(patch), async () => {
    await assert.rejects(() => verifier().verify(jwt({ ...base, ...patch }), 'nonce'));
  });
  for (const header of [{ alg: 'none', kid: jwk.kid }, { alg: 'HS256', kid: jwk.kid }, { alg: 'RS256' },
    { alg: 'RS256', kid: 'unknown' }, { alg: 'RS256', kid: jwk.kid, jku: 'https://evil.invalid' },
    { alg: 'RS256', kid: jwk.kid, x5u: 'https://evil.invalid' }, { alg: 'RS256', kid: jwk.kid, crit: ['nonce'] }]) {
    await assert.rejects(() => verifier().verify(jwt(base, header), 'nonce'));
  }
  for (const malformed of [undefined, '', 'a.b', 'a.b.c.d', `${jwt(base)}=`, 'x'.repeat(16385)]) await assert.rejects(() => verifier().verify(malformed, 'nonce'));
  await assert.rejects(() => verifier().verify(jwt(base, undefined, other.privateKey), 'nonce'));
});

test('JWKS cache fixed URL, bounded unknown-kid refresh, rotation and outage fail closed', async () => {
  let time = now, calls = 0;
  const identity = verifier({ clock: () => time, transport: async (url, options) => {
    if (url === GLOBAL_JWKS) return new Response(JSON.stringify({ keys: [] }));
    calls++; assert.equal(url, JWKS); assert.equal(options.redirect, 'error');
    return new Response(JSON.stringify({ keys: [jwk] }));
  } });
  await identity.verify(jwt(claims('n')), 'n');
  await identity.verify(jwt(claims('n')), 'n');
  assert.equal(calls, 1);
  for (let i = 0; i < 5; i++) await assert.rejects(() => identity.verify(jwt(claims('n'), { alg: 'RS256', kid: 'new' }), 'n'));
  assert.equal(calls, 1);
  time += 30_001;
  await assert.rejects(() => identity.verify(jwt(claims('n'), { alg: 'RS256', kid: 'new' }), 'n'));
  assert.equal(calls, 2);
  await assert.rejects(() => verifier({ transport: async () => new Response(JSON.stringify({ keys: Array(33).fill(jwk) })) }).verify(jwt(claims('n')), 'n'));
  await assert.rejects(() => verifier({ transport: async () => { throw new Error('secret upstream detail'); } }).verify(jwt(claims('n')), 'n'), e => !e.message.includes('secret'));
  let rotatedTime = now, rotatedKeys = [jwk], rotationCalls = 0;
  const rotating = verifier({ clock: () => rotatedTime, transport: async () => {
    rotationCalls++; return new Response(JSON.stringify({ keys: rotatedKeys }));
  } });
  await rotating.verify(jwt(claims('n')), 'n');
  rotatedTime += 30_001; rotatedKeys = [{ ...jwk, kid: 'rotated-fixture' }];
  await rotating.verify(jwt(claims('n'), { alg: 'RS256', kid: 'rotated-fixture' }), 'n');
  assert.equal(rotationCalls, 2);
});

test('browser state/request and grant are one-use, bound, expire, callback fixed and PKCE required', () => {
  let time = now;
  const auth = new NativeAuth(':memory:', { clock: () => time });
  try {
    for (const patch of [{ code_challenge: 'bad' }, { callback: 'evil://auth' }, { state: '' }]) assert.throws(() => start(auth, patch));
    const request = start(auth), browser = auth.browser(request);
    assert.throws(() => auth.browser(request));
    assert.throws(() => auth.consumeState(browser.state, 'z'.repeat(43)));
    assert.throws(() => auth.consumeState(browser.state, browser.browser));
    const a = grant(auth);
    const tokens = auth.exchange(a);
    assert.equal(tokens.account_id, a.account); assert.equal(tokens.expires_in, 900);
    assert.throws(() => auth.exchange(a));
    for (const patch of [{ code_verifier: 'wrong'.repeat(10) }, { callback: 'evil://auth' }]) {
      const b = grant(auth); assert.throws(() => auth.exchange({ ...b, ...patch })); assert.throws(() => auth.exchange(b));
    }
    const expiredGrant = grant(auth); time += 60_000; assert.throws(() => auth.exchange(expiredGrant));
    const expiredRequest = start(auth); time += 600_000; assert.throws(() => auth.browser(expiredRequest));
    const state = auth.browser(start(auth)); time += 600_000; assert.throws(() => auth.consumeState(state.state, state.browser));
  } finally { auth.close(); }
});

test('account re-login stable; access isolation, refresh race/replay revocation and logout', async () => {
  let time = now; const auth = new NativeAuth(':memory:', { clock: () => time });
  try {
    const a = auth.exchange(grant(auth, 'A')), again = auth.exchange(grant(auth, 'A')), b = auth.exchange(grant(auth, 'B'));
    assert.equal(a.account_id, again.account_id); assert.notEqual(a.account_id, b.account_id);
    assert.equal(auth.authenticate(a.access_token).account, a.account_id);
    assert.throws(() => auth.authenticate(a.refresh_token));
    const races = await Promise.allSettled([Promise.resolve().then(() => auth.refresh(a.refresh_token)), Promise.resolve().then(() => auth.refresh(a.refresh_token))]);
    assert.equal(races.filter(r => r.status === 'fulfilled').length, 1);
    const winner = races.find(r => r.status === 'fulfilled').value;
    assert.throws(() => auth.authenticate(winner.access_token)); assert.throws(() => auth.refresh(winner.refresh_token));
    assert.throws(() => auth.authenticate(a.access_token));
    assert.equal(auth.authenticate(again.access_token).account, a.account_id);
    auth.revoke(auth.authenticate(b.access_token).family);
    assert.throws(() => auth.authenticate(b.access_token)); assert.throws(() => auth.refresh(b.refresh_token));
    time += 900_000; assert.throws(() => auth.authenticate(again.access_token));
    const rotated = auth.refresh(again.refresh_token); assert.equal(rotated.refresh_expires_in, 30 * 86400 - 900);
    time = now + REFRESH_MS; assert.throws(() => auth.refresh(rotated.refresh_token));
  } finally { auth.close(); }
});

test('SQLite restart preserves pending, account mapping, sessions and refresh replay; secrets hashed and permissions private', async () => {
  const dir = await mkdtemp(join(tmpdir(), 'pony-native-auth-')), path = join(dir, 'private', 'sessions.sqlite');
  let auth;
  try {
    auth = new NativeAuth(path, { clock: () => now });
    const pending = auth.browser(start(auth));
    const tokens = auth.exchange(grant(auth));
    const rotated = auth.refresh(tokens.refresh_token);
    auth.close();
    auth = new NativeAuth(path, { clock: () => now });
    assert.ok(auth.consumeState(pending.state, pending.browser));
    assert.equal(auth.exchange(grant(auth)).account_id, tokens.account_id);
    assert.equal(auth.authenticate(rotated.access_token).account, tokens.account_id);
    assert.throws(() => auth.refresh(tokens.refresh_token));
    assert.throws(() => auth.authenticate(rotated.access_token));
    const raw = await readFile(path);
    for (const secret of [tokens.access_token, tokens.refresh_token, rotated.access_token, pending.browser]) assert.equal(raw.includes(Buffer.from(secret)), false);
    assert.equal((await stat(path)).mode & 0o777, 0o600);
    assert.equal((await stat(join(dir, 'private'))).mode & 0o777, 0o700);
  } finally { auth?.close(); await rm(dir, { recursive: true, force: true }); }
});

test('bounded pending authorization limit recovers after expiry', () => {
  let time = now; const auth = new NativeAuth(':memory:', { clock: () => time });
  try {
    for (let i = 0; i < 50; i++) start(auth);
    assert.throws(() => start(auth), { status: 429 });
    time += 600_000; assert.ok(start(auth));
  } finally { auth.close(); }
});

test('durable family refresh quota limits current token without consuming it; expired access pruned, replay tombstones retained', async () => {
  const dir = await mkdtemp(join(tmpdir(), 'pony-native-quota-')), path = join(dir, 'sessions.sqlite');
  let time = now, auth;
  try {
    auth = new NativeAuth(path, { clock: () => time });
    const initial = auth.exchange(grant(auth));
    let current = initial;
    for (let i = 0; i < 6; i++) current = auth.refresh(current.refresh_token);
    const family = auth.authenticate(current.access_token).family;
    const rows = auth.db.prepare('SELECT count(*) AS n FROM tokens WHERE family=?').get(family).n;
    assert.throws(() => auth.refresh(current.refresh_token), { status: 429 });
    assert.equal(auth.db.prepare('SELECT count(*) AS n FROM tokens WHERE family=?').get(family).n, rows);
    assert.equal(auth.db.prepare('SELECT used FROM tokens WHERE secret=?').get(hash(current.refresh_token)).used, 0);
    assert.equal(auth.db.prepare('SELECT rotations FROM families WHERE id=?').get(family).rotations, 6);
    auth.close(); auth = new NativeAuth(path, { clock: () => time });
    assert.throws(() => auth.refresh(current.refresh_token), { status: 429 });
    time += 900_001;
    current = auth.refresh(current.refresh_token);
    assert.equal(auth.db.prepare("SELECT count(*) AS n FROM tokens WHERE family=? AND kind='access'").get(family).n, 1);
    assert.equal(auth.db.prepare("SELECT count(*) AS n FROM tokens WHERE family=? AND kind='refresh'").get(family).n, 8);
    assert.throws(() => auth.refresh(initial.refresh_token), { status: 401 });
    assert.throws(() => auth.authenticate(current.access_token), { status: 401 });
  } finally { auth?.close(); await rm(dir, { recursive: true, force: true }); }
});

test('family absolute4096 rotation bound remains after minute reset; used-token replay always revokes even at both quotas', () => {
  let time = now; const auth = new NativeAuth(':memory:', { clock: () => time });
  try {
    const initial = auth.exchange(grant(auth));
    const family = auth.authenticate(initial.access_token).family;
    auth.db.prepare('UPDATE families SET rotations=4095 WHERE id=?').run(family);
    const final = auth.refresh(initial.refresh_token);
    assert.equal(auth.db.prepare('SELECT rotations FROM families WHERE id=?').get(family).rotations, 4096);
    assert.throws(() => auth.refresh(final.refresh_token), { status: 429 });
    time += 60_000;
    assert.throws(() => auth.refresh(final.refresh_token), { status: 429 });
    auth.db.prepare('UPDATE families SET rotation_window=?, rotation_count=6 WHERE id=?').run(time, family);
    assert.throws(() => auth.refresh(initial.refresh_token), { status: 401 });
    assert.equal(auth.db.prepare('SELECT revoked FROM families WHERE id=?').get(family).revoked, 1);
    assert.throws(() => auth.authenticate(final.access_token), { status: 401 });
  } finally { auth.close(); }
});

test('additive quota migration retains existing sessions and counts previous refresh tombstones', async () => {
  const dir = await mkdtemp(join(tmpdir(), 'pony-native-migration-')), path = join(dir, 'sessions.sqlite');
  let old, auth;
  try {
    old = new DatabaseSync(path);
    old.exec(`CREATE TABLE families (id TEXT PRIMARY KEY, account TEXT NOT NULL, expires INTEGER NOT NULL, revoked INTEGER NOT NULL DEFAULT 0);
      CREATE TABLE tokens (secret TEXT PRIMARY KEY, kind TEXT NOT NULL, family TEXT NOT NULL, expires INTEGER NOT NULL, used INTEGER NOT NULL DEFAULT 0);`);
    old.prepare('INSERT INTO families VALUES (?,?,?,0)').run('fixture-family', 'fixture-account', now + REFRESH_MS);
    for (const [value, kind, used] of [['m', 'refresh', 0], ['n', 'refresh', 1], ['o', 'refresh', 1], ['p', 'access', 0]]) {
      old.prepare('INSERT INTO tokens VALUES (?,?,?,?,?)').run(hash(value.repeat(43)), kind, 'fixture-family', now + REFRESH_MS, used);
    }
    old.close(); old = null;
    auth = new NativeAuth(path, { clock: () => now });
    assert.equal(auth.authenticate('p'.repeat(43)).account, 'fixture-account');
    assert.equal(auth.db.prepare('SELECT rotations FROM families').get().rotations, 2);
    const rotated = auth.refresh('m'.repeat(43));
    assert.equal(auth.db.prepare('SELECT rotations FROM families').get().rotations, 3);
    assert.throws(() => auth.refresh('n'.repeat(43)), { status: 401 });
    assert.throws(() => auth.authenticate(rotated.access_token), { status: 401 });
  } finally { old?.close(); auth?.close(); await rm(dir, { recursive: true, force: true }); }
});


test('fixed identity reasons retain public error/status and nonenumerable metadata', async () => {
  const cases = [
    [undefined, 'MISSING_JWT'], ['', 'MISSING_JWT'], ['bad', 'JWT_FORMAT'],
    ['eA.eA.eA', 'JWT_JSON'],
    [jwt(claims('n'), { alg: 'RS256', kid: jwk.kid, jku: 'secret-header' }), 'HEADER_PARAMETERS'],
    [jwt(null), 'CLAIMS_FORMAT'],
    [jwt(claims('n'), { alg: 'none', kid: jwk.kid }), 'HEADER_ALGORITHM'],
    [jwt(claims('n'), { alg: 'RS256' }), 'HEADER_KEY_ID'],
    [jwt(claims('n'), { alg: 'RS256', kid: jwk.kid, typ: 'malicious-type' }), 'HEADER_TYPE'],
    [jwt(claims('n'), null), 'HEADER_FORMAT'],
    [jwt(claims('n'), { alg: 'RS256', kid: 'secret-unknown-kid' }), 'KEY_MISSING'],
    [jwt(claims('n'), undefined, other.privateKey), 'SIGNATURE'],
    ...[
      [{ iss: 'secret-issuer' }, 'ISSUER'], [{ aud: 'secret-audience' }, 'AUDIENCE'],
      [{ azp: 'secret-azp' }, 'AUTHORIZED_PARTY'], [{ sub: '' }, 'SUBJECT'],
      [{ nonce: 'secret-nonce' }, 'NONCE'], [{ exp: 'secret-time' }, 'TIME_FORMAT'],
      [{ exp: now / 1000 }, 'EXPIRED'], [{ iat: now / 1000 + 31 }, 'ISSUED_AT'],
      [{ exp: now / 1000 + 86401 }, 'TIME_RANGE'], [{ nbf: now / 1000 + 1 }, 'NOT_BEFORE'],
    ].map(([patch, reason]) => [jwt({ ...claims('n'), ...patch }), reason]),
  ];
  for (const [value, reason] of cases) {
    await assert.rejects(() => verifier().verify(value, 'n'), error => {
      assert.equal(error.message, 'Native authorization invalid or expired');
      assert.equal(error.status, 401); assert.equal(error.reason, AUTH_REASON[reason]);
      assert.equal(Object.hasOwn(JSON.parse(JSON.stringify(error)), 'reason'), false);
      return true;
    });
  }
  for (const [data, reason] of [[{}, 'KEYS_FORMAT'], [{ keys: [jwk, jwk] }, 'KEYS_DUPLICATE']]) {
    await assert.rejects(() => verifier({ transport: async () => new Response(JSON.stringify(data)) }).verify(jwt(claims('n')), 'n'),
      { message: 'Native authorization invalid or expired', status: 401, reason: AUTH_REASON[reason] });
  }
  await assert.rejects(() => verifier({ transport: async () => { throw new Error('secret-provider'); } }).verify(jwt(claims('n')), 'n'),
    { message: 'Native identity provider unavailable or invalid response', status: 502, reason: AUTH_REASON.KEYS_UNAVAILABLE });
});

test('state reasons distinguish missing, expired and wrong browser without changing consumption', () => {
  let time = now;
  const auth = new NativeAuth(':memory:', { clock: () => time });
  const fails = (action, reason) => assert.throws(action, error => {
    assert.equal(error.message, 'Native authorization invalid or expired');
    assert.equal(error.status, 401); assert.equal(error.reason, AUTH_REASON[reason]);
    assert.equal(Object.getOwnPropertyDescriptor(error, 'reason').enumerable, false);
    return true;
  });
  try {
    fails(() => auth.consumeState(undefined, undefined), 'STATE_FORMAT');
    fails(() => auth.consumeState('native.invalid', undefined), 'PENDING_FORMAT');
    fails(() => auth.consumeState(`native.${'x'.repeat(43)}`, undefined), 'PENDING_MISSING');
    for (const browser of [undefined, 'malicious-cookie', 'z'.repeat(43)]) {
      const flow = auth.browser(start(auth));
      fails(() => auth.consumeState(flow.state, browser), 'WRONG_BROWSER');
      fails(() => auth.consumeState(flow.state, flow.browser), 'PENDING_MISSING');
    }
    const expired = auth.browser(start(auth)); time += 600_000;
    fails(() => auth.consumeState(expired.state, expired.browser), 'PENDING_EXPIRED');
    // Existing pruning remains unchanged: after pruning an expired row is missing.
    auth.prune();
    fails(() => auth.consumeState(expired.state, expired.browser), 'PENDING_MISSING');
  } finally { auth.close(); }
});

async function missing(identity, payload = claims('n'), key = rsa.privateKey) {
  let rejection;
  await assert.rejects(() => identity.verify(jwt(payload, undefined, key), 'n'), error => {
    rejection = error;
    assert.equal(error.status, 401); assert.equal(error.reason, 'KEY_MISSING');
    assert.equal(error.message, 'Native authorization invalid or expired');
    assert.equal(Object.getOwnPropertyDescriptor(error, 'observation').enumerable, false);
    assert.equal(JSON.stringify(error).includes('GLOBAL_'), false);
    assert.deepEqual(Object.keys(error.observation).sort(), ['cnMatch', 'cnSource', 'globalResult']);
    return true;
  });
  return rejection.observation;
}
const observedVerifier = (cn = [], global = [jwk], extra = {}) => verifier({ transport: async (url, options) => {
  assert.ok(url === JWKS || url === GLOBAL_JWKS);
  assert.equal(options.redirect, 'error'); assert.ok(options.signal instanceof AbortSignal);
  return new Response(JSON.stringify({ keys: url === JWKS ? cn : global }));
}, ...extra });

test('missing key fresh/cache CN raw filtered versus absent; snapshots only change on successful refresh', async () => {
  for (const [cn, match] of [[[], 'RAW_ABSENT'], [[{ ...jwk, use: 'enc', d: 'private-not-retained' }], 'RAW_MATCH_FILTERED']]) {
    let time = now;
    const identity = observedVerifier(cn, [jwk], { clock: () => time });
    assert.deepEqual(await missing(identity), { cnSource: 'FRESH_THIS_ATTEMPT', cnMatch: match, globalResult: 'GLOBAL_SIGNATURE_VALID_CN_CLAIMS_OK' });
    assert.deepEqual(await missing(identity), { cnSource: 'CACHE_REFRESH_THROTTLED', cnMatch: match, globalResult: 'SKIPPED_THROTTLED' });
    assert.equal(JSON.stringify(identity).includes('private-not-retained'), false);
    const snapshot = identity.rawKeys, generation = identity.generation;
    time += 30_001; identity.transport = async () => { throw new Error('provider-secret'); };
    await assert.rejects(() => identity.refresh(), { reason: 'KEYS_UNAVAILABLE' });
    assert.equal(identity.rawKeys, snapshot); assert.equal(identity.generation, generation);
  }
  const identity = observedVerifier(); identity.lastRefresh = now;
  assert.deepEqual(await missing(identity), { cnSource: 'NO_VALID_SNAPSHOT', cnMatch: 'UNKNOWN', globalResult: 'GLOBAL_SIGNATURE_VALID_CN_CLAIMS_OK' });
});

test('joined CN refresh is fresh for each waiting attempt; global observation never queues', async () => {
  let releaseCN, releaseGlobal, enteredGlobal;
  const cn = new Promise(resolve => { releaseCN = resolve; });
  const global = new Promise(resolve => { releaseGlobal = resolve; });
  const entered = new Promise(resolve => { enteredGlobal = resolve; });
  let globals = 0;
  const identity = verifier({ transport: async url => {
    if (url === JWKS) { await cn; return new Response('{"keys":[]}'); }
    assert.equal(url, GLOBAL_JWKS); globals++; enteredGlobal(); await global;
    return new Response(JSON.stringify({ keys: [jwk] }));
  } });
  const one = missing(identity), two = missing(identity);
  releaseCN(); await entered;
  const busy = await two;
  assert.equal(busy.cnSource, 'FRESH_THIS_ATTEMPT'); assert.equal(busy.globalResult, 'SKIPPED_BUSY');
  releaseGlobal(); assert.equal((await one).globalResult, 'GLOBAL_SIGNATURE_VALID_CN_CLAIMS_OK');
  assert.equal(globals, 1);
});

test('global shadow uses every unchanged CN claim predicate only after valid signature', async () => {
  const cases = [
    [{}, 'OK'], [{ iss: 'https://auth.tesla.com/oauth2/v3' }, 'FAIL_ISSUER'],
    [{ aud: 'other' }, 'FAIL_AUDIENCE'], [{ aud: ['fixture-client', 'other'] }, 'FAIL_AUDIENCE'],
    [{ azp: 'other' }, 'FAIL_AUTHORIZED_PARTY'], [{ sub: '' }, 'FAIL_SUBJECT'],
    [{ nonce: 'other' }, 'FAIL_NONCE'], [{ exp: 'bad' }, 'FAIL_TIME_FORMAT'],
    [{ exp: now / 1000 }, 'FAIL_EXPIRED'], [{ iat: now / 1000 + 31 }, 'FAIL_ISSUED_AT'],
    [{ exp: now / 1000 + 86401 }, 'FAIL_TIME_RANGE'], [{ nbf: now / 1000 + 1 }, 'FAIL_NOT_BEFORE'],
  ];
  for (const [patch, stage] of cases) {
    assert.equal((await missing(observedVerifier(), { ...claims('n'), ...patch })).globalResult, `GLOBAL_SIGNATURE_VALID_CN_CLAIMS_${stage}`);
    assert.equal((await missing(observedVerifier(), { ...claims('n'), ...patch }, other.privateKey)).globalResult, 'GLOBAL_SIGNATURE_INVALID');
  }
  let time = now;
  const identity = observedVerifier([], [jwk], { clock: () => time, transport: async url => {
    if (url === GLOBAL_JWKS) time += 7200_000;
    return new Response(JSON.stringify({ keys: url === JWKS ? [] : [jwk] }));
  } });
  assert.equal((await missing(identity)).globalResult, 'GLOBAL_SIGNATURE_VALID_CN_CLAIMS_OK');
});

test('global public filter, duplicate, missing, weak and empty RSA keys stay observational', async () => {
  const weak = generateKeyPairSync('rsa', { modulusLength: 1024 });
  for (const [keys, result] of [
    [[], 'GLOBAL_RAW_ABSENT'], [[{ ...jwk, use: 'enc' }], 'GLOBAL_RAW_MATCH_FILTERED'],
    [[{ ...jwk, alg: 'RS512' }], 'GLOBAL_RAW_MATCH_FILTERED'],
    [[{ ...jwk, key_ops: ['sign'] }], 'GLOBAL_RAW_MATCH_FILTERED'],
    [[{ ...jwk, kty: 'EC' }], 'GLOBAL_RAW_MATCH_FILTERED'],
    [[{ ...jwk, n: 'x'.repeat(1401) }], 'GLOBAL_RAW_MATCH_FILTERED'],
    [[jwk, jwk], 'GLOBAL_KEYS_DUPLICATE'],
    [[{ ...jwk, ...weak.publicKey.export({ format: 'jwk' }) }], 'GLOBAL_KEY_WEAK'],
    // Node 24/OpenSSL imports empty RSA parameters as a zero-strength key, not an import error.
    // GLOBAL_KEY_INVALID import-failure coverage would require a mocked importer.
    [[{ ...jwk, n: '', e: '' }], 'GLOBAL_KEY_WEAK'],
  ]) assert.equal((await missing(observedVerifier([], keys))).globalResult, result);
});

test('global failure consumes independent attempt slot; timeout covers body and aborts/cancels', async () => {
  for (const mode of ['throw', 'status', 'redirect', 'size', 'count', 'json', 'timeout-fetch', 'timeout-body']) {
    let calls = 0, signal, cancelled = false;
    const identity = verifier({ transport: async (url, options) => {
      if (url === JWKS) return new Response('{"keys":[]}');
      assert.equal(url, GLOBAL_JWKS); assert.equal(options.redirect, 'error');
      calls++; signal = options.signal;
      if (mode === 'throw') throw new Error('provider-secret');
      if (mode === 'status') return new Response('provider-secret', { status: 503 });
      if (mode === 'redirect') return { ok: true, redirected: true };
      if (mode === 'size') return new Response('x'.repeat(131073));
      if (mode === 'count') return new Response(JSON.stringify({ keys: Array(33).fill(jwk) }));
      if (mode === 'json') return new Response('provider-secret');
      if (mode === 'timeout-fetch') return new Promise((_, reject) => signal.addEventListener('abort', () => reject(new Error('cancelled')), { once: true }));
      return new Response(new ReadableStream({ cancel() { cancelled = true; } }));
    } });
    assert.equal((await missing(identity)).globalResult, 'OBSERVATION_FAILED', mode);
    assert.equal(signal.aborted, true, mode);
    if (mode === 'timeout-body') assert.equal(cancelled, true);
    assert.equal((await missing(identity)).globalResult, 'SKIPPED_THROTTLED', mode);
    assert.equal(calls, 1, mode);
  }
});

test('global endpoint is never contacted on normal CN success or non-missing failures', async () => {
  let globals = 0;
  const identity = observedVerifier([jwk], [], { transport: async url => {
    if (url === GLOBAL_JWKS) globals++;
    return new Response(JSON.stringify({ keys: [jwk] }));
  } });
  await identity.verify(jwt(claims('n')), 'n');
  await assert.rejects(() => identity.verify(jwt({ ...claims('n'), iss: 'other' }), 'n'), { reason: 'ISSUER' });
  await assert.rejects(() => identity.verify(jwt(claims('n'), undefined, other.privateKey), 'n'), { reason: 'SIGNATURE' });
  await assert.rejects(() => identity.verify('bad', 'n'), { reason: 'JWT_FORMAT' });
  assert.equal(globals, 0);
});
