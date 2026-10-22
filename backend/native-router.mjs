import { join } from 'node:path';
import { mkdirSync, chmodSync } from 'node:fs';
import { NativeAuth, IdentityVerifier, CALLBACK, nativeJSON, AUTH_REASON } from './native-auth.mjs';
import { SafeError, Vault, TeslaClient, AUTH, FLEET, SCOPES, isRecord } from './core.mjs';
import { OwnerPairing, ownerBrowserRouter } from './owner-pairing.mjs';
import { HistoryStore } from './history.mjs';

const COOKIE = '__Secure-pony_native';
const cookieValue = req => req.headers.cookie?.split(';').map(s => s.trim()).find(s => s.startsWith(`${COOKIE}=`))?.slice(COOKIE.length + 1);
const diagnosticReasons = new Set(Object.values(AUTH_REASON));
const cnSources = new Set(['FRESH_THIS_ATTEMPT', 'CACHE_REFRESH_THROTTLED', 'NO_VALID_SNAPSHOT']);
const cnMatches = new Set(['RAW_ABSENT', 'RAW_MATCH_FILTERED', 'ELIGIBLE_MATCH', 'UNKNOWN']);
const globalResults = new Set(['SKIPPED_BUSY', 'SKIPPED_THROTTLED', 'OBSERVATION_FAILED',
  'GLOBAL_KEYS_DUPLICATE', 'GLOBAL_RAW_MATCH_FILTERED', 'GLOBAL_RAW_ABSENT', 'GLOBAL_KEY_INVALID',
  'GLOBAL_KEY_WEAK', 'GLOBAL_SIGNATURE_INVALID', 'GLOBAL_SIGNATURE_VALID_CN_CLAIMS_OK',
  ...['ISSUER', 'AUDIENCE', 'AUTHORIZED_PARTY', 'SUBJECT', 'NONCE', 'TIME_FORMAT', 'EXPIRED', 'ISSUED_AT', 'TIME_RANGE', 'NOT_BEFORE']
    .map(stage => `GLOBAL_SIGNATURE_VALID_CN_CLAIMS_FAIL_${stage}`)]);
const stageReason = Object.freeze({ callback_state: AUTH_REASON.CALLBACK_REJECTED, token_exchange: AUTH_REASON.TOKEN_EXCHANGE_REJECTED,
  identity: AUTH_REASON.IDENTITY_REJECTED, credentials: AUTH_REASON.CREDENTIALS_REJECTED, grant: AUTH_REASON.GRANT_REJECTED });
const cookie = (value, age) => `${COOKIE}=${value}; Path=/oauth/callback; HttpOnly; Secure; SameSite=Lax; Max-Age=${age}`;

async function body(req) {
  if (!/^application\/json(?:\s*;\s*charset=utf-8)?$/i.test(req.headers['content-type'] || '')) throw new SafeError('JSON required', 415);
  let timer;
  const read = async () => {
    let size = 0; const chunks = [];
    try {
      for await (const chunk of req.iterator({ destroyOnReturn: false })) {
        size += chunk.length; if (size > 4096) throw new SafeError('Request too large', 413);
        chunks.push(chunk);
      }
      const value = JSON.parse(Buffer.concat(chunks).toString('utf8'));
      if (!isRecord(value)) throw new Error();
      return value;
    } catch (e) { req.resume(); throw e instanceof SafeError ? e : new SafeError('Invalid JSON'); }
  };
  try { return await Promise.race([read(), new Promise((_, reject) => { timer = setTimeout(() => { req.resume(); reject(new SafeError('Request timeout', 408)); }, 10_000); })]); }
  finally { clearTimeout(timer); }
}

export function createNativeRouter(settings, { transport = fetch, clock = Date.now, auth, verifier, accountFactory, ownerContext, diagnostics = console.error } = {}) {
  const enabled = settings.nativeEnabled === true;
  if (enabled && (!settings.origin || settings.nativeApprovedOrigin !== settings.origin || settings.missing?.length || !settings.key)) {
    throw new SafeError('Native requires complete server configuration and explicitly approved PUBLIC_ORIGIN', 503);
  }
  const base = settings.dir ? join(settings.dir, 'native') : null;
  if (enabled && !base && !auth) throw new SafeError('Native private storage required', 503);
  if (enabled && base) { mkdirSync(base, { recursive: true, mode: 0o700 }); chmodSync(base, 0o700); }
  const store = enabled ? (auth ?? new NativeAuth(join(base, 'sessions.sqlite'), { clock })) : null;
  let canonicalOwnerOrigin = false;
  try { const origin = new URL(settings.origin); canonicalOwnerOrigin = origin.protocol === 'https:' && origin.origin === settings.origin; } catch {}
  if (settings.ownerPairingEnabled === true && (!enabled || !canonicalOwnerOrigin || !settings.adminPassword
    || !ownerContext?.client || !ownerContext?.vault || !ownerContext?.history)) {
    throw new SafeError('Owner pairing requires approved native HTTPS configuration and shared owner context', 503);
  }
  const owner = store ? new OwnerPairing(store, settings, { clock }) : null;
  const ownerBrowser = ownerBrowserRouter(owner, settings);
  const identity = verifier ?? new IdentityVerifier(settings.clientId, { transport, clock });
  const accounts = new Map();
  const sources = new Map();
  function limitAnonymous(req, kind) {
    const now = clock();
    for (const [key, entry] of sources) if (now - entry.window >= 60_000) sources.delete(key);
    // Only the transport peer is trusted. Forwarded/X-Forwarded-For never select a bucket.
    const key = req.socket.remoteAddress || 'unknown';
    let entry = sources.get(key);
    if (!entry) {
      if (sources.size >= 1024) throw new SafeError('Native admission capacity reached', 429);
      entry = { window: now, starts: 0, failures: 0 }; sources.set(key, entry);
    }
    const field = kind === 'start' ? 'starts' : 'failures';
    if (++entry[field] > (kind === 'start' ? 20 : 40)) throw new SafeError('Native admission rate limit', 429);
  }
  function account(id) {
    if (accounts.has(id)) return accounts.get(id);
    // Never evict active clients: TeslaClient owns a rotating-token serialization queue.
    if (accounts.size >= 100) throw new SafeError('Native account capacity reached', 503);
    let value;
    if (accountFactory) value = accountFactory(id);
    else {
      const dir = join(base, 'accounts', id);
      mkdirSync(dir, { recursive: true, mode: 0o700 }); chmodSync(dir, 0o700);
      const vault = new Vault(dir, settings.key);
      value = { vault, client: new TeslaClient(settings, vault, transport), history: new HistoryStore(join(dir, 'history.sqlite'), { clock }) };
    }
    value.active = false; value.lastProbe = -Infinity;
    value.fleetActive = false; value.fleetWindow = clock(); value.fleetRequests = 0;
    accounts.set(id, value); return value;
  }
  const router = async (req, res, url) => {
    if (await ownerBrowser(req, res, url)) return true;
    const nativePath = url.pathname.startsWith('/api/native/v1/');
    const callback = url.pathname === '/oauth/callback' && (url.searchParams.getAll('state').some(s => s.startsWith('native.'))
      || (cookieValue(req) && !url.searchParams.has('state')));
    if (!nativePath && !callback) return false;
    const json = (value, status = 200) => { res.writeHead(status, { 'Content-Type': 'application/json; charset=utf-8' }); res.end(JSON.stringify(value)); };
    const redirect = location => { res.writeHead(303, { Location: location }); res.end(); };
    res.setHeader('Cache-Control', 'no-store'); res.setHeader('Referrer-Policy', 'no-referrer');
    res.setHeader('X-Content-Type-Options', 'nosniff');
    res.setHeader('Content-Security-Policy', "default-src 'none'; frame-ancestors 'none'; base-uri 'none'");
    if (callback) res.setHeader('Set-Cookie', cookie('', 0));
    let stage = 'callback_state';
    try {
      if (!enabled) throw new SafeError('Native route unavailable', 404);
      if (req.url.length > 8192 || req.rawHeaders.reduce((n, h) => n + Buffer.byteLength(h), 0) > 8192) throw new SafeError('Request too large', 413);
      if (req.headers.authorization && !/^Bearer [A-Za-z0-9_-]{43}$/.test(req.headers.authorization)) throw new SafeError('Native bearer required', 401);
      if (req.headers.origin !== undefined && req.headers.origin !== settings.origin) throw new SafeError('Invalid origin', 403);
      if (callback) {
        if (!store.validState(url.searchParams.get('state'), cookieValue(req))) limitAnonymous(req, 'failure');
        if (req.method !== 'GET' || [...url.searchParams.keys()].some(k => url.searchParams.getAll(k).length !== 1)) throw new SafeError('Invalid native callback');
        const pending = store.consumeState(url.searchParams.get('state'), cookieValue(req));
        if (url.searchParams.has('error')) throw new SafeError('Native authorization cancelled');
        const code = url.searchParams.get('code');
        if (!code || code.length > 4096) throw new SafeError('Invalid authorization code');
        stage = 'token_exchange';
        const token = await nativeJSON(`${AUTH}/token`, { method: 'POST', headers: { 'Content-Type': 'application/x-www-form-urlencoded' },
          body: new URLSearchParams({ grant_type: 'authorization_code', client_id: settings.clientId, client_secret: settings.clientSecret,
            audience: FLEET, redirect_uri: `${settings.origin}/oauth/callback`, code }) }, transport);
        if (!isRecord(token)) throw new SafeError('Invalid native token response', 502);
        // Identity MUST be authenticated before mapping accounts or touching any vault.
        stage = 'identity';
        const principal = await identity.verify(token.id_token, pending.nonce);
        stage = 'credentials';
        if (typeof token.access_token !== 'string' || !token.access_token.trim() || token.access_token.length > 16384
          || typeof token.refresh_token !== 'string' || !token.refresh_token.trim() || token.refresh_token.length > 16384
          || !Number.isFinite(token.expires_in) || token.expires_in <= 0 || token.expires_in > 86400) throw new SafeError('Invalid native token response', 502);
        const id = store.account(principal), context = account(id);
        await context.client.serialized(() => context.vault.write({ access_token: token.access_token, refresh_token: token.refresh_token,
          expires_at: clock() + token.expires_in * 1000 }));
        stage = 'grant';
        const grant = store.grant(id, { code_challenge: pending.code_challenge });
        redirect(`${CALLBACK}?${new URLSearchParams({ grant, state: pending.state })}`); return true;
      }
      const path = url.pathname.slice('/api/native/v1'.length);
      if (req.method === 'POST' && ['/auth/start', '/auth/exchange', '/auth/refresh', '/pair/start', '/pair/exchange'].includes(path)) {
        if (path === '/auth/start' || path === '/pair/start') limitAnonymous(req, 'start');
        if (req.headers.authorization) throw new SafeError('Bearer not accepted on token endpoint', 401);
        const input = await body(req);
        if (url.search && path.startsWith('/pair/')) throw new SafeError('Query parameters not accepted');
        if (path === '/pair/start') {
          const request = owner.start(input);
          json({ authorization_url: `${settings.origin}/owner/devices/pair?${new URLSearchParams({ request })}`, expires_in: 600 });
        } else if (path === '/pair/exchange') {
          // Failed owner grant submissions have their own bounded anonymous cost;
          // owner and Tesla grant namespaces never intersect.
          try { json(owner.exchange(input)); }
          catch (error) { limitAnonymous(req, 'failure'); throw error; }
        } else if (path === '/auth/start') {
          const request = store.start(input);
          json({ authorization_url: `${settings.origin}/api/native/v1/auth/browser?${new URLSearchParams({ request })}`, expires_in: 600 });
        } else if (path === '/auth/exchange') {
          if (!store.validExchange(input)) limitAnonymous(req, 'failure');
          json(store.exchange(input));
        } else {
          // Possession of a valid refresh credential (including a replay that must
          // revoke its family) is not throttled by unrelated anonymous failures.
          if (!store.validRefresh(input.refresh_token)) limitAnonymous(req, 'failure');
          json(store.refresh(input.refresh_token));
        }
        return true;
      }
      if (req.method === 'GET' && path === '/auth/browser') {
        if (!store.peek(url.searchParams.get('request'), 'request')) limitAnonymous(req, 'failure');
        if (req.headers.authorization || url.searchParams.getAll('request').length !== 1) throw new SafeError('Invalid browser authorization');
        const issued = store.browser(url.searchParams.get('request'));
        res.setHeader('Set-Cookie', cookie(issued.browser, 600));
        const query = new URLSearchParams({ client_id: settings.clientId, redirect_uri: `${settings.origin}/oauth/callback`,
          response_type: 'code', scope: SCOPES, state: issued.state, nonce: issued.nonce, locale: 'zh-CN' });
        redirect(`${AUTH}/authorize?${query}`); return true;
      }
      const vehiclePath = /^\/vehicles\/([A-HJ-NPR-Z0-9]{17})\/(probe|snapshot)$/.exec(path);
      const supported = (req.method === 'GET' && ['/session', '/vehicles'].includes(path))
        || (req.method === 'POST' && path === '/auth/logout')
        || (vehiclePath && req.method === (vehiclePath[2] === 'probe' ? 'POST' : 'GET'));
      if (!supported) throw new SafeError('Native route not found', 404);
      if (url.search) throw new SafeError('Query parameters not accepted');
      const session = store.authenticate(req.headers.authorization?.slice(7));
      if (req.method === 'POST') await body(req);
      if (path === '/auth/logout') { store.revoke(session.family); json({ logged_out: true, tesla_revoked: false, data_deleted: false }); return true; }
      if (path === '/session') {
        json({ account_id: session.account, ...(session.principal_type ? { principal_type: session.principal_type } : {}), features: { vehicles: true, probe: true, snapshot: true,
          commands: false, telemetry: false, charge_history: false, trips: false }, native_deployment_verified: false }); return true;
      }
      const context = session.principal_type === 'service_owner' ? ownerContext : account(session.account);
      if (!context) throw new SafeError('Owner context unavailable', 503);
      if (clock() - context.fleetWindow >= 60_000) { context.fleetWindow = clock(); context.fleetRequests = 0; }
      // One account-owned Fleet operation at a time, shared by list, snapshot and
      // probe. Every admitted snapshot still performs a fresh membership check.
      if (context.fleetActive || context.fleetRequests >= 30) throw new SafeError('Native vehicle request limit', 429);
      context.fleetRequests++; context.fleetActive = true;
      try {
        if (path === '/vehicles') { json({ vehicles: await context.client.vehicles() }); return true; }
        const [, vin, operation] = vehiclePath;
        if (operation === 'probe') {
          if (context.active || clock() - context.lastProbe < 15_000) throw new SafeError('Wait at least 15 seconds before probing', 429);
          context.active = true; context.lastProbe = clock();
          try {
            if (!(await context.client.vehicles()).some(v => v.vin === vin)) throw new SafeError('Vehicle not authorized', 403);
            const result = await context.client.probe(vin);
            if (result.vehicle?.vin !== vin) throw new SafeError('Invalid vehicle response', 502);
            context.history.saveProbe(result); json(result);
          } finally { context.active = false; }
        } else {
          if (!(await context.client.vehicles()).some(v => v.vin === vin)) throw new SafeError('Vehicle not authorized', 403);
          context.history.prune();
          const snapshot = context.history.snapshot(vin);
          if (!snapshot) throw new SafeError('No cached vehicle data', 404);
          json({ snapshot });
        }
      } finally { context.fleetActive = false; }
    } catch (error) {
      if (callback) {
        // Allowlist only: never log messages, URLs, credentials or identity data.
        // Logging is best effort and cannot alter the authentication response.
        try {
          const reason = error?.reason;
          Promise.resolve(diagnostics(`[pony-native-auth] ${stage} ${diagnosticReasons.has(reason) ? reason : stageReason[stage]}`)).catch(() => {});
        } catch {}
        try {
          if (stage === 'identity' && error?.reason === AUTH_REASON.KEY_MISSING && error.observation) {
            const { cnSource, cnMatch, globalResult } = error.observation;
            const source = cnSources.has(cnSource) ? cnSource : 'NO_VALID_SNAPSHOT';
            const match = cnMatches.has(cnMatch) ? cnMatch : 'UNKNOWN';
            const result = globalResults.has(globalResult) ? globalResult : 'OBSERVATION_FAILED';
            Promise.resolve(diagnostics(`[pony-native-key-check] ${source} ${match} ${result}`)).catch(() => {});
          }
        } catch {}
      }
      json({ error: error instanceof SafeError ? error.message : 'Native session unavailable' }, error instanceof SafeError ? error.status : 500);
    }
    return true;
  };
  router.close = () => { for (const value of accounts.values()) value.history?.close(); store?.close(); };
  return router;
}
