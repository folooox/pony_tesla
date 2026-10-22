import { randomBytes, randomUUID, createHmac, timingSafeEqual } from 'node:crypto';
import { CALLBACK, REFRESH_MS, hash, isOpaque } from './native-auth.mjs';
import { SafeError, isRecord } from './core.mjs';

const opaque = () => randomBytes(32).toString('base64url');
const fail = () => new SafeError('Owner pairing invalid or expired', 401);
const COOKIE = '__Secure-pony_owner';
const esc = value => String(value).replace(/[&<>"']/g, c => ({ '&': '&amp;', '<': '&lt;', '>': '&gt;', '"': '&quot;', "'": '&#39;' }[c]));
const keys = (input, expected) => isRecord(input) && Object.keys(input).sort().join(',') === [...expected].sort().join(',');
const validPKCE = (input, pending) => input.callback === CALLBACK && typeof input.code_verifier === 'string'
  && /^[A-Za-z0-9._~-]{43,128}$/.test(input.code_verifier) && hash(input.code_verifier) === pending.code_challenge;
const cookie = (value, age = 600) => `${COOKIE}=${value}; Path=/owner/devices; Secure; HttpOnly; SameSite=Strict; Max-Age=${age}`;
function browserCookie(req) {
  const matches = (req.headers.cookie || '').split(';').map(x => x.trim()).filter(x => x.startsWith(`${COOKIE}=`));
  return matches.length === 1 ? matches[0].slice(COOKIE.length + 1) : null;
}
function basic(req, password) {
  const header = req.headers.authorization;
  if (!password || typeof header !== 'string' || !/^Basic [A-Za-z0-9+/]+=*$/.test(header)) return false;
  const actual = Buffer.from(header.slice(6), 'base64'), expected = Buffer.from(`owner:${password}`);
  return actual.length === expected.length && timingSafeEqual(actual, expected);
}
async function form(req) {
  if (!/^application\/x-www-form-urlencoded(?:\s*;\s*charset=utf-8)?$/i.test(req.headers['content-type'] || '')) throw new SafeError('Form required', 415);
  let timer;
  const read = async () => {
    let size = 0; const chunks = [];
    try {
      for await (const chunk of req.iterator({ destroyOnReturn: false })) {
        size += chunk.length; if (size > 1024) throw new SafeError('Request too large', 413);
        chunks.push(chunk);
      }
      const text = Buffer.concat(chunks).toString('utf8');
      if (/%(?![0-9a-f]{2})/i.test(text)) throw fail();
      const params = new URLSearchParams(text);
      if ([...params.keys()].some(k => params.getAll(k).length !== 1)) throw fail();
      return Object.fromEntries(params);
    } catch (e) { req.resume(); throw e; }
  };
  try { return await Promise.race([read(), new Promise((_, reject) => { timer = setTimeout(() => { req.resume(); reject(new SafeError('Request timeout', 408)); }, 10_000); })]); }
  finally { clearTimeout(timer); }
}

// Explicit service-owner provenance. No Tesla identity is synthesized or adopted.
// All transitions are synchronous SQLite transactions on the native session store.
export class OwnerPairing {
  constructor(auth, settings, { clock = Date.now } = {}) {
    this.auth = auth; this.db = auth.db; this.settings = settings; this.clock = clock;
    this.db.exec(`CREATE TABLE IF NOT EXISTS owner_meta (id INTEGER PRIMARY KEY CHECK(id=1), generation TEXT NOT NULL, account TEXT NOT NULL);
      CREATE TABLE IF NOT EXISTS owner_devices (family TEXT PRIMARY KEY, generation TEXT NOT NULL, created INTEGER NOT NULL);
      CREATE TABLE IF NOT EXISTS owner_pending (secret TEXT PRIMARY KEY, kind TEXT NOT NULL, expires INTEGER NOT NULL, payload TEXT NOT NULL);`);
    this.sync();
    auth.ownerPolicy = row => this.checkFamily(row.family);
    auth.ownerRevoked = () => this.db.exec('DELETE FROM owner_pending');
  }
  enabled() { return this.settings.ownerPairingEnabled === true && this.settings.nativeEnabled === true; }
  sync() {
    const { adminPassword, key } = this.settings;
    if (!adminPassword || !key) {
      this.db.exec("UPDATE families SET revoked=1 WHERE principal_type='service_owner'; DELETE FROM owner_pending;");
      if (this.enabled()) throw new SafeError('Owner configuration unavailable', 503);
      return;
    }
    // Keyed, domain-separated password generation: never persist the password or
    // an unkeyed password digest. The existing private vault key stays server-side.
    const generation = createHmac('sha256', key).update('pony-owner-generation-v1\0').update(adminPassword).digest('base64url');
    const previous = this.db.prepare('SELECT * FROM owner_meta WHERE id=1').get();
    if (!previous) this.db.prepare('INSERT INTO owner_meta VALUES (1,?,?)').run(generation, randomUUID());
    else if (previous.generation !== generation) {
      this.db.exec("UPDATE families SET revoked=1 WHERE principal_type='service_owner'; DELETE FROM owner_pending;");
      this.db.prepare('UPDATE owner_meta SET generation=? WHERE id=1').run(generation);
    }
    if (!this.enabled()) {
      // Disabling is a revocation boundary, not a pause that resurrects sessions.
      this.db.exec("UPDATE families SET revoked=1 WHERE principal_type='service_owner'; DELETE FROM owner_pending;");
    }
    this.generation = generation;
  }
  requireEnabled() { this.sync(); if (!this.enabled()) throw new SafeError('Owner pairing unavailable', 404); }
  checkFamily(family) {
    this.requireEnabled();
    const row = this.db.prepare(`SELECT d.generation,f.revoked,f.expires FROM owner_devices d JOIN families f ON f.id=d.family WHERE d.family=?`).get(family);
    if (!row || row.generation !== this.generation || row.revoked || row.expires <= this.clock()) throw fail();
  }
  prune() {
    this.auth.prune();
    this.db.prepare('DELETE FROM owner_pending WHERE expires<=?').run(this.clock());
    this.db.exec('DELETE FROM owner_devices WHERE family NOT IN (SELECT id FROM families)');
  }
  put(kind, payload, expires) {
    this.prune();
    if (this.db.prepare('SELECT count(*) AS n FROM owner_pending WHERE kind=?').get(kind).n >= 100) throw new SafeError('Owner pending capacity reached', 429);
    const secret = opaque();
    this.db.prepare('INSERT INTO owner_pending VALUES (?,?,?,?)').run(hash(secret), kind, expires, JSON.stringify(payload));
    return secret;
  }
  row(secret, kind) {
    if (!isOpaque(secret)) throw fail();
    const row = this.db.prepare('SELECT * FROM owner_pending WHERE secret=? AND kind=?').get(hash(secret), kind);
    if (!row || row.expires <= this.clock()) throw fail();
    return { ...row, payload: JSON.parse(row.payload) };
  }
  start(input) {
    this.requireEnabled();
    if (!keys(input, ['code_challenge', 'callback', 'state', 'verification_code']) || !isOpaque(input.code_challenge)
      || input.callback !== CALLBACK || typeof input.state !== 'string' || !/^[A-Za-z0-9_-]{16,128}$/.test(input.state)
      || typeof input.verification_code !== 'string' || !/^[0-9A-F]{8}$/.test(input.verification_code)) throw fail();
    return this.auth.transaction(() => this.put('request', { code_challenge: input.code_challenge, state: input.state,
      code_hash: hash(input.verification_code), generation: this.generation }, this.clock() + 600_000));
  }
  browser(request) {
    this.requireEnabled();
    return this.auth.transaction(() => {
      const row = this.row(request, 'request');
      this.db.prepare('DELETE FROM owner_pending WHERE secret=?').run(row.secret);
      const browser = opaque(), csrf = opaque();
      const intent = this.put('intent', { ...row.payload, browser: hash(browser), csrf: hash(csrf), attempts: 0, nextAttempt: 0 }, row.expires);
      return { browser, csrf, intent };
    });
  }
  decide(input, browser) {
    this.requireEnabled();
    if (!keys(input, ['intent', 'csrf', 'decision', 'verification_code']) || !['approve', 'deny'].includes(input.decision)
      || !isOpaque(input.csrf) || !isOpaque(browser) || typeof input.verification_code !== 'string' || input.verification_code.length > 8) throw fail();
    const result = this.auth.transaction(() => {
      const row = this.row(input.intent, 'intent'), p = row.payload;
      if (p.generation !== this.generation || p.browser !== hash(browser) || p.csrf !== hash(input.csrf)) throw fail();
      if (input.decision === 'deny') {
        this.db.prepare('DELETE FROM owner_pending WHERE secret=?').run(row.secret);
        return { error: 'pairing_rejected', state: p.state };
      }
      if (this.clock() < p.nextAttempt) return { limited: true };
      if (!/^[0-9A-F]{8}$/.test(input.verification_code) || hash(input.verification_code) !== p.code_hash) {
        p.attempts++; p.nextAttempt = this.clock() + 2000;
        if (p.attempts >= 5) this.db.prepare('DELETE FROM owner_pending WHERE secret=?').run(row.secret);
        else this.db.prepare('UPDATE owner_pending SET payload=? WHERE secret=?').run(JSON.stringify(p), row.secret);
        return { invalid: true, format: !/^[0-9A-F]{8}$/.test(input.verification_code) };
      }
      if (this.db.prepare("SELECT count(*) AS n FROM families WHERE principal_type='service_owner' AND revoked=0 AND expires>?").get(this.clock()).n >= 100) {
        throw new SafeError('Owner device capacity reached', 429);
      }
      this.db.prepare('DELETE FROM owner_pending WHERE secret=?').run(row.secret);
      const account = this.db.prepare('SELECT account FROM owner_meta WHERE id=1').get().account, family = randomUUID();
      this.db.prepare("INSERT INTO families (id,account,expires,revoked,principal_type) VALUES (?,?,?,0,'service_owner')").run(family, account, this.clock() + REFRESH_MS);
      this.db.prepare('INSERT INTO owner_devices VALUES (?,?,?)').run(family, this.generation, this.clock());
      const grant = this.put('grant', { family, account, code_challenge: p.code_challenge }, this.clock() + 60_000);
      return { grant, state: p.state };
    });
    if (result.limited) throw Object.assign(new SafeError('请稍后再输入核对码。', 429), { ownerRetry: true });
    if (result.invalid) {
      const retry = this.db.prepare("SELECT 1 FROM owner_pending WHERE secret=? AND kind='intent'").get(hash(input.intent));
      const message = !retry ? '本次请求已无法继续，请返回Pony重新开始配对。'
        : result.format ? '请输入8位核对码，仅含0–9或A–F。' : '核对码不匹配，请核对Pony中显示的内容后再输入。';
      throw Object.assign(new SafeError(message, 401), { ownerRetry: Boolean(retry), ownerTerminal: !retry });
    }
    return result;
  }
  exchange(input) {
    this.requireEnabled();
    if (!keys(input, ['grant', 'code_verifier', 'callback'])) throw fail();
    // Commit consumption before PKCE rejection, matching the legacy anti-theft rule.
    const pending = this.auth.transaction(() => {
      const row = this.row(input.grant, 'grant');
      this.db.prepare('DELETE FROM owner_pending WHERE secret=?').run(row.secret);
      return row.payload;
    });
    if (!validPKCE(input, pending)) throw fail();
    return this.auth.transaction(() => { this.checkFamily(pending.family); return this.auth.issue(pending.account, pending.family); });
  }
  management() {
    this.requireEnabled();
    return this.auth.transaction(() => {
      const browser = opaque(), csrf = opaque();
      const intent = this.put('admin', { browser: hash(browser), csrf: hash(csrf), generation: this.generation }, this.clock() + 600_000);
      const devices = this.db.prepare(`SELECT d.family,d.created,f.revoked,f.expires,EXISTS(SELECT 1 FROM tokens t WHERE t.family=d.family AND t.kind='refresh') AS claimed FROM owner_devices d JOIN families f ON f.id=d.family WHERE f.revoked=0 AND f.expires>? ORDER BY d.created DESC LIMIT 100`).all(this.clock());
      return { browser, csrf, intent, devices };
    });
  }
  revoke(input, browser) {
    this.requireEnabled();
    if (!keys(input, ['intent', 'csrf', 'family']) || !isOpaque(input.csrf) || !isOpaque(browser) || !/^[a-f0-9-]{36}$/.test(input.family)) throw fail();
    this.auth.transaction(() => {
      const row = this.row(input.intent, 'admin'), p = row.payload;
      if (p.generation !== this.generation || p.browser !== hash(browser) || p.csrf !== hash(input.csrf)) throw fail();
      if (!this.db.prepare('SELECT family FROM owner_devices WHERE family=?').get(input.family)) throw fail();
      this.auth.revoke(input.family);
      // Revoke all outstanding enrollment and management intents. An old tab may
      // not restore access; a fresh, explicit enrollment must be started.
      this.db.exec("DELETE FROM owner_pending WHERE kind IN ('request','intent','admin')");
      this.db.prepare("DELETE FROM owner_pending WHERE kind='grant' AND json_extract(payload,'$.family')=?").run(input.family);
    });
  }
}

export function ownerBrowserRouter(owner, settings) {
  return async (req, res, url) => {
    if (!(url.pathname === '/owner/devices' || url.pathname.startsWith('/owner/devices/'))) return false;
    const json = (error, status) => { res.writeHead(status, { 'Content-Type': 'application/json; charset=utf-8' }); res.end(JSON.stringify({ error })); };
    const html = (text, status = 200) => { res.setHeader('Referrer-Policy', 'same-origin'); res.writeHead(status, { 'Content-Type': 'text/html; charset=utf-8' }); res.end(`<!doctype html><html lang="zh-CN"><meta charset="utf-8"><title>设备配对</title><body><main>${text}</main></body></html>`); };
    const redirect = location => { res.writeHead(303, { Location: location }); res.end(); };
    res.setHeader('Cache-Control', 'no-store'); res.setHeader('Referrer-Policy', 'no-referrer');
    res.setHeader('X-Content-Type-Options', 'nosniff');
    // WebKit checks a form submission's redirect destination against form-action.
    // Permit only our fixed callback authority on pairing, never arbitrary custom
    // schemes, destinations from form fields, or broader navigation policies.
    const formAction = url.pathname === '/owner/devices/pair' ? `'self' ${CALLBACK}` : "'self'";
    res.setHeader('Content-Security-Policy', `default-src 'none'; form-action ${formAction}; frame-ancestors 'none'; base-uri 'none'`);
    try {
      if (!owner) throw new SafeError('Owner pairing unavailable', 404);
      owner.requireEnabled();
      if (req.url.length > 2048 || req.rawHeaders.reduce((n, h) => n + Buffer.byteLength(h), 0) > 8192) throw new SafeError('Request too large', 413);
      if (!basic(req, settings.adminPassword)) {
        res.setHeader('WWW-Authenticate', 'Basic realm="Pony owner devices", charset="UTF-8"');
        throw new SafeError('请先登录后台，再确认这次设备配对。', 401);
      }
      if (req.headers.origin !== undefined && req.headers.origin !== settings.origin) throw new SafeError('Invalid origin', 403);
      const hidden = (name, value) => `<input type="hidden" name="${name}" value="${esc(value)}">`;
      const pairForm = (flow, error = '', status = 200) => html(`<h1>确认设备配对</h1>${error ? `<p role="alert">${esc(error)}</p>` : ''}<p>此设备正在请求连接当前后台。确认后，它可使用这里已有的Tesla车辆授权，访问当前开放的车辆信息。</p><dl><dt>后台地址</dt><dd>${esc(settings.origin)}</dd><dt>请求设备</dt><dd>待配对设备</dd></dl><p>只有你本人刚发起此请求时才确认。设备名称不能证明身份；不认识的请求请拒绝。</p><p>车辆控制、行程采集和充电历史暂不可用。</p><form method="post" action="/owner/devices/pair">${hidden('intent', flow.intent)}${hidden('csrf', flow.csrf)}<label>Pony中显示的核对码 <input type="text" name="verification_code" placeholder="输入8位核对码" maxlength="8" pattern="[0-9A-F]{8}" autocapitalize="characters" spellcheck="false" autocomplete="off"></label><p>输入此设备Pony页面显示的8个字符，字符为0–9或A–F。</p><p>请在请求创建后的10分钟内完成确认，打开页面不会延长有效期。</p><button name="decision" value="approve">确认配对</button><button name="decision" value="deny" formnovalidate>拒绝请求</button></form>`, status);
      if (req.method === 'GET' && url.pathname === '/owner/devices/pair') {
        if ([...url.searchParams.keys()].join(',') !== 'request' || url.searchParams.getAll('request').length !== 1) throw fail();
        const flow = owner.browser(url.searchParams.get('request'));
        res.setHeader('Set-Cookie', cookie(flow.browser));
        pairForm(flow);
      } else if (req.method === 'POST' && url.pathname === '/owner/devices/pair') {
        if (url.search || req.headers.origin !== settings.origin) throw new SafeError('Invalid origin', 403);
        const fields = await form(req);
        let result;
        try { result = owner.decide(fields, browserCookie(req)); }
        catch (error) {
          if (error.ownerRetry === true) { pairForm({ intent: fields.intent, csrf: fields.csrf }, error.message, error.status); return true; }
          if (error.ownerTerminal === true) { html(`<h1>本次请求已无法继续，请返回Pony重新开始配对。</h1>`, error.status); return true; }
          throw error;
        }
        res.setHeader('Set-Cookie', cookie('', 0));
        redirect(`${CALLBACK}?${new URLSearchParams(result)}`);
      } else if (req.method === 'GET' && url.pathname === '/owner/devices' && !url.search) {
        const page = owner.management(); res.setHeader('Set-Cookie', cookie(page.browser));
        html(`<h1>已配对设备</h1><p>设备名称不能证明身份。</p>${page.devices.length ? '' : '<h2>暂无已配对设备</h2><p>在Pony中开始配对，再到这里确认。</p>'}${page.devices.map(d => `<section><h2>设备 ${esc(d.family.slice(0, 8))}</h2><p>批准时间 ${esc(new Date(d.created).toISOString())} — ${d.claimed ? '已领取连接凭据（不代表设备已完成本地安全保存）' : d.created + 60000 <= owner.clock() ? '连接未完成：领取已超时' : '配对请求已批准，等待领取连接凭据'}</p><form method="post" action="/owner/devices/revoke">${hidden('intent', page.intent)}${hidden('csrf', page.csrf)}${hidden('family', d.family)}<fieldset><legend>撤销此设备的配对？</legend><p>此设备将无法再通过本次配对访问后台。已有Tesla授权和后台记录会保留；未完成的配对请求也将失效。</p><button>撤销配对</button></fieldset></form></section>`).join('')}`);
      } else if (req.method === 'POST' && url.pathname === '/owner/devices/revoke') {
        if (url.search || req.headers.origin !== settings.origin) throw new SafeError('Invalid origin', 403);
        owner.revoke(await form(req), browserCookie(req)); res.setHeader('Set-Cookie', cookie('', 0)); redirect('/owner/devices');
      } else throw new SafeError('Owner route not found', 404);
    } catch (error) { json(error instanceof SafeError ? error.message : 'Owner pairing unavailable', error instanceof SafeError ? error.status : 500); }
    return true;
  };
}
