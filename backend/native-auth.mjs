import { randomBytes, randomUUID, createHash, createPublicKey, verify } from 'node:crypto';
import { DatabaseSync } from 'node:sqlite';
import { mkdirSync, chmodSync } from 'node:fs';
import { dirname } from 'node:path';
import { SafeError, isRecord, AUTH } from './core.mjs';

export const CALLBACK = 'pony-native://auth';
export const JWKS = `${AUTH}/discovery/keys`;
export const ACCESS_MS = 900_000;
export const REFRESH_MS = 30 * 86400_000;
const opaque = () => randomBytes(32).toString('base64url');
export const hash = value => createHash('sha256').update(value).digest('base64url');
// Diagnostic values are fixed, never derived from provider/request contents.
export const AUTH_REASON = Object.freeze(Object.fromEntries([
  'STATE_FORMAT', 'PENDING_FORMAT', 'PENDING_MISSING', 'PENDING_EXPIRED', 'WRONG_BROWSER',
  'MISSING_JWT', 'JWT_FORMAT', 'JWT_JSON', 'HEADER_FORMAT', 'HEADER_ALGORITHM', 'HEADER_KEY_ID', 'HEADER_PARAMETERS', 'HEADER_TYPE', 'CLAIMS_FORMAT',
  'KEYS_UNAVAILABLE', 'KEYS_FORMAT', 'KEYS_DUPLICATE', 'KEY_MISSING', 'KEY_EXPIRED',
  'KEY_INVALID', 'KEY_WEAK', 'SIGNATURE', 'ISSUER', 'AUDIENCE', 'AUTHORIZED_PARTY',
  'SUBJECT', 'NONCE', 'TIME_FORMAT', 'EXPIRED', 'ISSUED_AT', 'TIME_RANGE', 'NOT_BEFORE',
  'CALLBACK_REJECTED', 'TOKEN_EXCHANGE_REJECTED', 'IDENTITY_REJECTED',
  'CREDENTIALS_REJECTED', 'GRANT_REJECTED',
].map(value => [value, value])));
const reasoned = (error, reason) => Object.defineProperty(error, 'reason', { value: reason });
const denied = reason => reasoned(new SafeError('Native authorization invalid or expired', 401), reason);
export const isOpaque = value => typeof value === 'string' && /^[A-Za-z0-9_-]{43}$/.test(value);

// Fixed endpoint, bounded streaming reads, no upstream errors/bodies in client errors.
export async function nativeJSON(url, options, transport = fetch) {
  try {
    const response = await transport(url, { ...options, redirect: 'error', signal: AbortSignal.timeout(20_000) });
    if (!response.ok) throw denied();
    const chunks = []; let size = 0;
    for await (const chunk of response.body) {
      size += chunk.length;
      if (size > 131072) { await response.body.cancel?.().catch(() => {}); throw denied(); }
      chunks.push(chunk);
    }
    return JSON.parse(Buffer.concat(chunks).toString('utf8'));
  } catch { throw new SafeError('Native identity provider unavailable or invalid response', 502); }
}

// Observation is strictly separate from authentication and never caches request data.
export const GLOBAL_JWKS = 'https://auth.tesla.com/oauth2/v3/discovery/keys';
const eligibleKeys = keys => keys.filter(k => isRecord(k) && k.kty === 'RSA' && typeof k.kid === 'string'
  && k.kid.length > 0 && k.kid.length <= 128 && (!k.use || k.use === 'sig')
  && (!k.alg || k.alg === 'RS256') && (!k.key_ops || (Array.isArray(k.key_ops) && k.key_ops.includes('verify')))
  && typeof k.n === 'string' && k.n.length <= 1400 && typeof k.e === 'string' && k.e.length <= 16);
const publicSnapshot = keys => keys.filter(isRecord).map(k => ({
  ...Object.fromEntries(['kty', 'kid', 'use', 'alg', 'n', 'e']
    .filter(field => typeof k[field] === 'string' && k[field].length <= 1400).map(field => [field, k[field]])),
  ...(Array.isArray(k.key_ops) ? { key_ops: k.key_ops.slice(0, 32)
    .filter(value => typeof value === 'string' && value.length <= 128) } : {}),
}));

async function observationJSON(transport) {
  const controller = new AbortController();
  let timer, reader;
  const read = async () => {
    const response = await transport(GLOBAL_JWKS, { redirect: 'error', signal: controller.signal });
    reader = response.body?.getReader();
    if (!response.ok || response.redirected || !reader) throw new Error();
    const chunks = []; let size = 0;
    while (true) {
      const { done, value } = await reader.read();
      if (done) break;
      size += value.byteLength;
      if (size > 131072) throw new Error();
      chunks.push(Buffer.from(value));
    }
    const data = JSON.parse(Buffer.concat(chunks).toString('utf8'));
    if (!isRecord(data) || !Array.isArray(data.keys) || data.keys.length > 32) throw new Error();
    return data.keys;
  };
  try {
    return await Promise.race([read(), new Promise((_, reject) => {
      timer = setTimeout(() => { controller.abort(); reject(new Error()); }, 1500);
    })]);
  } finally {
    clearTimeout(timer); controller.abort();
    try { Promise.resolve(reader?.cancel()).catch(() => {}); } catch {}
  }
}

export class IdentityVerifier {
  constructor(clientId, { transport = fetch, clock = Date.now } = {}) {
    this.clientId = clientId; this.transport = transport; this.clock = clock;
    this.rawKeys = null; this.generation = 0; this.observationActive = false; this.lastObservation = -Infinity;
    this.keys = []; this.until = 0; this.lastRefresh = -Infinity; this.loading = null;
  }
  async refresh() {
    if (this.loading) return this.loading;
    // Unknown kids may cause at most one network refresh per 30 seconds globally.
    if (this.clock() - this.lastRefresh < 30_000) return;
    this.lastRefresh = this.clock();
    this.loading = (async () => {
      let data;
      try { data = await nativeJSON(JWKS, {}, this.transport); }
      catch (error) { throw reasoned(error, AUTH_REASON.KEYS_UNAVAILABLE); }
      if (!isRecord(data) || !Array.isArray(data.keys) || data.keys.length > 32) throw denied(AUTH_REASON.KEYS_FORMAT);
      const keys = eligibleKeys(data.keys);
      if (new Set(keys.map(k => k.kid)).size !== keys.length) throw denied(AUTH_REASON.KEYS_DUPLICATE);
      this.rawKeys = publicSnapshot(data.keys); this.generation++;
      this.keys = keys; this.until = this.clock() + 300_000;
    })();
    try { await this.loading; } finally { this.loading = null; }
  }
  async verify(token, nonce) {
    if (typeof token !== 'string' || !token || token.length > 16384) throw denied(token === undefined || token === null || token === '' ? AUTH_REASON.MISSING_JWT : AUTH_REASON.JWT_FORMAT);
    const parts = token.split('.');
    if (parts.length !== 3 || parts.some(p => !/^[A-Za-z0-9_-]+$/.test(p) || Buffer.from(p, 'base64url').toString('base64url') !== p)) throw denied(AUTH_REASON.JWT_FORMAT);
    let header, claims;
    try { header = JSON.parse(Buffer.from(parts[0], 'base64url')); claims = JSON.parse(Buffer.from(parts[1], 'base64url')); }
    catch { throw denied(AUTH_REASON.JWT_JSON); }
    if (!isRecord(header)) throw denied(AUTH_REASON.HEADER_FORMAT);
    if (header.alg !== 'RS256') throw denied(AUTH_REASON.HEADER_ALGORITHM);
    if (typeof header.kid !== 'string' || !header.kid || header.kid.length > 128) throw denied(AUTH_REASON.HEADER_KEY_ID);
    if (Object.keys(header).some(k => !['alg', 'kid', 'typ'].includes(k))) throw denied(AUTH_REASON.HEADER_PARAMETERS);
    if (header.typ && header.typ !== 'JWT') throw denied(AUTH_REASON.HEADER_TYPE);
    if (!isRecord(claims)) throw denied(AUTH_REASON.CLAIMS_FORMAT);
    const generation = this.generation;
    if (this.until <= this.clock()) await this.refresh();
    let key = this.keys.find(k => k.kid === header.kid);
    if (!key) { await this.refresh(); key = this.keys.find(k => k.kid === header.kid); }
    if (!key) {
      const rejectedAt = this.clock() / 1000;
      const error = denied(AUTH_REASON.KEY_MISSING);
      const cnSource = this.rawKeys === null ? 'NO_VALID_SNAPSHOT'
        : this.generation !== generation ? 'FRESH_THIS_ATTEMPT' : 'CACHE_REFRESH_THROTTLED';
      const cnMatch = this.rawKeys === null ? 'UNKNOWN' : this.keys.some(k => k.kid === header.kid)
        ? 'ELIGIBLE_MATCH' : this.rawKeys.some(k => k.kid === header.kid) ? 'RAW_MATCH_FILTERED' : 'RAW_ABSENT';
      let globalResult;
      try { globalResult = await this.observe(header.kid, parts, claims, nonce, rejectedAt); }
      catch { globalResult = 'OBSERVATION_FAILED'; }
      Object.defineProperty(error, 'observation', { value: Object.freeze({ cnSource, cnMatch, globalResult }) });
      throw error;
    }
    if (this.until <= this.clock()) throw denied(AUTH_REASON.KEY_EXPIRED);
    this.validate(key, parts, claims, nonce);
    return { issuer: AUTH, subject: claims.sub };
  }
  async observe(kid, parts, claims, nonce, evaluationTime) {
    if (this.observationActive) return 'SKIPPED_BUSY';
    if (this.clock() - this.lastObservation < 30_000) return 'SKIPPED_THROTTLED';
    this.lastObservation = this.clock(); this.observationActive = true;
    try {
      const raw = await observationJSON(this.transport);
      const keys = eligibleKeys(raw);
      if (new Set(keys.map(k => k.kid)).size !== keys.length) return 'GLOBAL_KEYS_DUPLICATE';
      const key = keys.find(k => k.kid === kid);
      if (!key) return raw.some(k => isRecord(k) && k.kid === kid) ? 'GLOBAL_RAW_MATCH_FILTERED' : 'GLOBAL_RAW_ABSENT';
      try {
        this.validate(key, parts, claims, nonce, evaluationTime);
        return 'GLOBAL_SIGNATURE_VALID_CN_CLAIMS_OK';
      } catch (error) {
        if (error.reason === AUTH_REASON.KEY_INVALID) return 'GLOBAL_KEY_INVALID';
        if (error.reason === AUTH_REASON.KEY_WEAK) return 'GLOBAL_KEY_WEAK';
        if (error.reason === AUTH_REASON.SIGNATURE) return 'GLOBAL_SIGNATURE_INVALID';
        if (['ISSUER', 'AUDIENCE', 'AUTHORIZED_PARTY', 'SUBJECT', 'NONCE', 'TIME_FORMAT', 'EXPIRED', 'ISSUED_AT', 'TIME_RANGE', 'NOT_BEFORE'].includes(error.reason)) {
          return `GLOBAL_SIGNATURE_VALID_CN_CLAIMS_FAIL_${error.reason}`;
        }
        return 'OBSERVATION_FAILED';
      }
    } catch { return 'OBSERVATION_FAILED'; }
    finally { this.observationActive = false; }
  }
  validate(key, parts, claims, nonce, evaluationTime) {
    let publicKey;
    try { publicKey = createPublicKey({ key: { kty: 'RSA', n: key.n, e: key.e }, format: 'jwk' }); }
    catch { throw denied(AUTH_REASON.KEY_INVALID); }
    if (publicKey.asymmetricKeyDetails.modulusLength < 2048) throw denied(AUTH_REASON.KEY_WEAK);
    try {
      if (!verify('RSA-SHA256', Buffer.from(`${parts[0]}.${parts[1]}`), publicKey, Buffer.from(parts[2], 'base64url'))) throw denied();
    } catch { throw denied(AUTH_REASON.SIGNATURE); }
    const now = evaluationTime === undefined ? this.clock() / 1000 : evaluationTime;
    const aud = claims.aud;
    const audienceOK = aud === this.clientId || (Array.isArray(aud) && aud.length > 0 && aud.length <= 8
      && aud.every(a => typeof a === 'string') && new Set(aud).size === aud.length && aud.includes(this.clientId)
      && (aud.length === 1 || claims.azp === this.clientId));
    if (claims.iss !== AUTH) throw denied(AUTH_REASON.ISSUER);
    if (!audienceOK) throw denied(AUTH_REASON.AUDIENCE);
    if (claims.azp !== undefined && claims.azp !== this.clientId) throw denied(AUTH_REASON.AUTHORIZED_PARTY);
    if (typeof claims.sub !== 'string' || !claims.sub.trim() || claims.sub.length > 512) throw denied(AUTH_REASON.SUBJECT);
    if (typeof nonce !== 'string' || claims.nonce !== nonce) throw denied(AUTH_REASON.NONCE);
    if (!Number.isSafeInteger(claims.exp) || !Number.isSafeInteger(claims.iat)) throw denied(AUTH_REASON.TIME_FORMAT);
    if (claims.exp <= now) throw denied(AUTH_REASON.EXPIRED);
    if (claims.iat > now + 30 || claims.iat < now - 3600) throw denied(AUTH_REASON.ISSUED_AT);
    if (claims.exp <= claims.iat || claims.exp - claims.iat > 86400) throw denied(AUTH_REASON.TIME_RANGE);
    if (claims.nbf !== undefined && (!Number.isSafeInteger(claims.nbf) || claims.nbf > now)) throw denied(AUTH_REASON.NOT_BEFORE);
  }
}

// All session/grant secrets are hashed at rest. SQLite synchronous transactions make
// consume/rotate atomic even across multiple connections. Pending OAuth expires on disk.
export class NativeAuth {
  constructor(path, { clock = Date.now } = {}) {
    this.clock = clock;
    if (path !== ':memory:') { mkdirSync(dirname(path), { recursive: true, mode: 0o700 }); chmodSync(dirname(path), 0o700); }
    this.db = new DatabaseSync(path);
    if (path !== ':memory:') chmodSync(path, 0o600);
    this.db.exec(`PRAGMA journal_mode=DELETE; PRAGMA secure_delete=ON; PRAGMA busy_timeout=5000;
      CREATE TABLE IF NOT EXISTS accounts (id TEXT PRIMARY KEY, issuer TEXT NOT NULL, subject TEXT NOT NULL, UNIQUE(issuer,subject));
      CREATE TABLE IF NOT EXISTS pending (secret TEXT PRIMARY KEY, kind TEXT NOT NULL, expires INTEGER NOT NULL, payload TEXT NOT NULL);
      CREATE TABLE IF NOT EXISTS families (id TEXT PRIMARY KEY, account TEXT NOT NULL, expires INTEGER NOT NULL, revoked INTEGER NOT NULL DEFAULT 0);
      CREATE TABLE IF NOT EXISTS tokens (secret TEXT PRIMARY KEY, kind TEXT NOT NULL, family TEXT NOT NULL, expires INTEGER NOT NULL, used INTEGER NOT NULL DEFAULT 0);
      CREATE INDEX IF NOT EXISTS tokens_family ON tokens(family);
      CREATE INDEX IF NOT EXISTS tokens_expiry ON tokens(kind, expires);`);
    // Additive migration: preserve existing sessions and replay tombstones.
    this.transaction(() => {
      const columns = new Set(this.db.prepare('PRAGMA table_info(families)').all().map(row => row.name));
      for (const name of ['rotation_window', 'rotation_count', 'rotations']) {
        if (!columns.has(name)) this.db.exec(`ALTER TABLE families ADD COLUMN ${name} INTEGER NOT NULL DEFAULT 0`);
      }
      if (!columns.has('principal_type')) this.db.exec("ALTER TABLE families ADD COLUMN principal_type TEXT NOT NULL DEFAULT 'tesla'");
      if (!columns.has('rotations')) {
        this.db.exec(`UPDATE families SET rotations=MAX(0, (SELECT COUNT(*) FROM tokens
          WHERE family=families.id AND kind='refresh')-1)`);
      }
    });
  }
  close() { this.db.close(); }
  transaction(action) {
    this.db.exec('BEGIN IMMEDIATE');
    try { const result = action(); this.db.exec('COMMIT'); return result; }
    catch (e) { this.db.exec('ROLLBACK'); throw e; }
  }
  prune() {
    this.db.prepare("DELETE FROM tokens WHERE kind='access' AND expires<=?").run(this.clock());
    this.db.prepare('DELETE FROM pending WHERE expires<=?').run(this.clock());
    this.db.prepare('DELETE FROM tokens WHERE family IN (SELECT id FROM families WHERE expires<=?)').run(this.clock());
    this.db.prepare('DELETE FROM families WHERE expires<=?').run(this.clock());
  }
  put(kind, payload, ttl) {
    this.prune();
    const capacity = { request: 50, oauth: 100, grant: 100 }[kind];
    if (!capacity || this.db.prepare('SELECT count(*) AS n FROM pending WHERE kind=?').get(kind).n >= capacity) {
      throw new SafeError('Too many pending native requests', 429);
    }
    const secret = opaque();
    this.db.prepare('INSERT INTO pending VALUES (?,?,?,?)').run(hash(secret), kind, this.clock() + ttl, JSON.stringify(payload));
    return secret;
  }
  peek(secret, kind) {
    if (!isOpaque(secret)) return null;
    const row = this.db.prepare('SELECT payload, expires FROM pending WHERE secret=? AND kind=?').get(hash(secret), kind);
    return row && row.expires > this.clock() ? JSON.parse(row.payload) : null;
  }
  validState(state, browser) {
    const pending = typeof state === 'string' && state.startsWith('native.') ? this.peek(state.slice(7), 'oauth') : null;
    return Boolean(pending && isOpaque(browser) && pending.browser === hash(browser));
  }
  validExchange({ grant, code_verifier, callback }) {
    const pending = this.peek(grant, 'grant');
    return Boolean(pending && callback === CALLBACK && typeof code_verifier === 'string'
      && /^[A-Za-z0-9._~-]{43,128}$/.test(code_verifier) && hash(code_verifier) === pending.code_challenge);
  }
  validRefresh(secret) {
    try { this.token(secret, 'refresh'); return true; } catch { return false; }
  }
  take(secret, kind) {
    if (!isOpaque(secret)) throw denied(AUTH_REASON.PENDING_FORMAT);
    return this.transaction(() => {
      const row = this.db.prepare('SELECT * FROM pending WHERE secret=? AND kind=?').get(hash(secret), kind);
      if (!row) throw denied(AUTH_REASON.PENDING_MISSING);
      if (row.expires <= this.clock()) throw denied(AUTH_REASON.PENDING_EXPIRED);
      this.db.prepare('DELETE FROM pending WHERE secret=?').run(hash(secret));
      return JSON.parse(row.payload);
    });
  }
  start({ code_challenge, callback, state }) {
    if (!isOpaque(code_challenge) || callback !== CALLBACK || typeof state !== 'string' || !/^[A-Za-z0-9_-]{16,128}$/.test(state)) throw denied();
    return this.put('request', { code_challenge, callback, state }, 600_000);
  }
  browser(request) {
    const payload = this.take(request, 'request');
    const browser = opaque(), nonce = opaque();
    const state = `native.${this.put('oauth', { ...payload, browser: hash(browser), nonce }, 600_000)}`;
    return { state, browser, nonce };
  }
  consumeState(state, browser) {
    if (typeof state !== 'string' || !state.startsWith('native.')) throw denied(AUTH_REASON.STATE_FORMAT);
    const payload = this.take(state.slice(7), 'oauth');
    if (!isOpaque(browser) || hash(browser) !== payload.browser) throw denied(AUTH_REASON.WRONG_BROWSER);
    return payload;
  }
  account({ issuer, subject }) {
    const id = randomUUID();
    this.db.prepare('INSERT OR IGNORE INTO accounts VALUES (?,?,?)').run(id, issuer, subject);
    return this.db.prepare('SELECT id FROM accounts WHERE issuer=? AND subject=?').get(issuer, subject).id;
  }
  grant(account, pending) { return this.put('grant', { account, ...pending }, 60_000); }
  issue(account, family = null) {
    const now = this.clock();
    if (!family) {
      family = randomUUID();
      this.db.prepare('INSERT INTO families (id, account, expires, revoked) VALUES (?,?,?,0)').run(family, account, now + REFRESH_MS);
    }
    const expires = this.db.prepare('SELECT expires FROM families WHERE id=?').get(family).expires;
    const access = opaque(), refresh = opaque();
    this.db.prepare('INSERT INTO tokens VALUES (?,?,?,?,0)').run(hash(access), 'access', family, Math.min(now + ACCESS_MS, expires));
    this.db.prepare('INSERT INTO tokens VALUES (?,?,?,?,0)').run(hash(refresh), 'refresh', family, expires);
    return { access_token: access, refresh_token: refresh, token_type: 'Bearer', expires_in: Math.floor(Math.min(ACCESS_MS, expires - now) / 1000),
      refresh_expires_in: Math.floor((expires - now) / 1000), account_id: account };
  }
  exchange({ grant, code_verifier, callback }) {
    // Consume even incorrect PKCE attempts; a stolen grant cannot be brute-forced.
    const pending = this.take(grant, 'grant');
    if (callback !== CALLBACK || typeof code_verifier !== 'string' || !/^[A-Za-z0-9._~-]{43,128}$/.test(code_verifier)
      || hash(code_verifier) !== pending.code_challenge) throw denied();
    return this.transaction(() => this.issue(pending.account));
  }
  token(secret, kind) {
    if (!isOpaque(secret)) throw denied();
    const row = this.db.prepare(`SELECT t.*, f.account, f.revoked, f.expires AS family_expires,
      f.rotation_window, f.rotation_count, f.rotations, f.principal_type FROM tokens t
      JOIN families f ON t.family=f.id WHERE t.secret=? AND t.kind=?`).get(hash(secret), kind);
    if (!row || row.revoked || row.expires <= this.clock() || row.family_expires <= this.clock()) throw denied();
    if (row.principal_type === 'service_owner') {
      if (!this.ownerPolicy) throw denied();
      this.ownerPolicy(row);
    } else if (row.principal_type !== 'tesla') throw denied();
    return row;
  }
  authenticate(secret) {
    const row = this.token(secret, 'access');
    return { account: row.account, family: row.family, ...(row.principal_type === 'service_owner' ? { principal_type: 'service_owner' } : {}) };
  }
  refresh(secret) {
    // Persist owner generation/gate invalidation before opening the rotation
    // transaction: a rejected rotation must not roll that revocation back.
    if (this.ownerPolicy) this.token(secret, 'refresh');
    // Replay revocation must COMMIT, not be rolled back with the error.
    const result = this.transaction(() => {
      const row = this.token(secret, 'refresh');
      if (row.used) { this.revoke(row.family); return null; }
      // Credential-owned quota is independent of anonymous peer admission. Check
      // replay FIRST so exhausting either quota can never suppress revocation.
      const now = this.clock();
      const reset = now - row.rotation_window >= 60_000;
      const count = reset ? 0 : row.rotation_count;
      if (count >= 6 || row.rotations >= 4096) throw new SafeError('Native refresh rotation limit', 429);
      this.db.prepare(`UPDATE families SET rotation_window=?, rotation_count=?, rotations=rotations+1 WHERE id=?`)
        .run(reset ? now : row.rotation_window, count + 1, row.family);
      this.db.prepare("DELETE FROM tokens WHERE family=? AND kind='access' AND expires<=?").run(row.family, now);
      this.db.prepare('UPDATE tokens SET used=1 WHERE secret=?').run(hash(secret));
      return this.issue(row.account, row.family);
    });
    if (!result) throw denied();
    return result;
  }
  revoke(family) {
    this.db.prepare('UPDATE families SET revoked=1 WHERE id=?').run(family);
    const row = this.db.prepare('SELECT principal_type FROM families WHERE id=?').get(family);
    if (row?.principal_type === 'service_owner') this.ownerRevoked?.(family);
  }
}
