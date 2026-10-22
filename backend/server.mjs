import http from 'node:http';
import { timingSafeEqual } from 'node:crypto';
import { readFile } from 'node:fs/promises';
import { pathToFileURL } from 'node:url';
import { config, Vault, OAuthStates, TeslaClient, SafeError, isRecord, validVin } from './core.mjs';
import { HistoryStore, tripCSV } from './history.mjs';
import { readiness } from './readiness.mjs';
import { createNativeRouter } from './native-router.mjs';

async function readJSON(req, limit = 4096) {
  let size = 0;
  const chunks = [];
  try {
    for await (const chunk of req.iterator({ destroyOnReturn: false })) {
      size += chunk.length;
      if (size > limit) throw new SafeError('请求过大', 413);
      chunks.push(chunk);
    }
  } catch (error) { req.resume(); throw error; }
  try { return JSON.parse(Buffer.concat(chunks).toString('utf8')); }
  catch { throw new SafeError('请求格式无效'); }
}

function authorized(header, password) {
  if (!password || !header?.startsWith('Basic ')) return false;
  const actual = Buffer.from(header.slice(6), 'base64');
  const expected = Buffer.from(`owner:${password}`);
  return actual.length === expected.length && timingSafeEqual(actual, expected);
}

export function createApp(settings, client, vault, history = null, nativeRouter = null) {
  const states = new OAuthStates();
  // This exact singleton owns the legacy rotating Tesla client, vault, history,
  // concurrency lock and budget. Never put it in native per-account ownership.
  const ownerContext = { client, vault, history, active: false, lastProbe: -Infinity,
    fleetActive: false, fleetWindow: Date.now(), fleetRequests: 0 };
  nativeRouter ??= createNativeRouter(settings, { ownerContext });
  const sharedOwnerMode = settings.ownerPairingEnabled === true;
  function acquireFleet(probe = false) {
    const now = Date.now();
    if (now - ownerContext.fleetWindow >= 60_000) { ownerContext.fleetWindow = now; ownerContext.fleetRequests = 0; }
    if (ownerContext.fleetActive || ownerContext.fleetRequests >= 30) throw new SafeError('Shared vehicle request limit', 429);
    if (probe && (ownerContext.active || now - ownerContext.lastProbe < 15_000)) throw new SafeError('请等待至少 15 秒后再读取', 429);
    ownerContext.fleetActive = true; ownerContext.fleetRequests++;
    if (probe) { ownerContext.active = true; ownerContext.lastProbe = now; }
    return () => { ownerContext.fleetActive = false; if (probe) ownerContext.active = false; };
  }
  let probeActive = false;
  let lastProbe = 0;
  const server = http.createServer({ maxHeaderSize: 16384, requestTimeout: 15000, headersTimeout: 10000 }, async (req, res) => {
    res.setHeader('Cache-Control', 'no-store');
    res.setHeader('Referrer-Policy', 'no-referrer');
    res.setHeader('X-Content-Type-Options', 'nosniff');
    res.setHeader('Content-Security-Policy', "default-src 'none'; script-src 'self'; style-src 'self'; connect-src 'self'; form-action 'self' https://auth.tesla.cn; frame-ancestors 'none'; base-uri 'none'");
    const json = (value, status = 200) => { res.writeHead(status, { 'Content-Type': 'application/json; charset=utf-8' }); res.end(JSON.stringify(value)); };
    try {
      const url = new URL(req.url, 'http://localhost');
      // Native owns its namespace before Basic admin authentication, and only its
      // namespaced OAuth states. Neither router can borrow the other's identity.
      if (await nativeRouter(req, res, url)) return;
      if (url.pathname === '/healthz' && req.method === 'GET') return json({ status: settings.missing.length ? 'needs_configuration' : 'ready_for_authorization' });
      if (url.pathname === '/.well-known/appspecific/com.tesla.3p.public-key.pem' && req.method === 'GET') {
        let key;
        try { key = await readFile(`${settings.dir}/public-key.pem`); }
        catch { throw new SafeError('公钥尚未生成', 503); }
        res.writeHead(200, { 'Content-Type': 'application/x-pem-file' }); return res.end(key);
      }
      if (url.pathname === '/oauth/callback' && req.method === 'GET') {
        if (!client) throw new SafeError('应用配置尚未完成', 503);
        const cookie = req.headers.cookie?.split(';').map(s => s.trim()).find(s => s.startsWith('pony_oauth='))?.slice(11);
        states.consume(url.searchParams.get('state'), cookie);
        res.setHeader('Set-Cookie', 'pony_oauth=; Path=/oauth; HttpOnly; Secure; SameSite=Lax; Max-Age=0');
        if (url.searchParams.has('error')) throw new SafeError('Tesla 授权未完成，请返回测试页重试');
        const code = url.searchParams.get('code');
        if (!code || code.length > 4096) throw new SafeError('缺少有效授权码');
        await client.exchange(code);
        res.writeHead(303, { Location: '/' }); return res.end();
      }
      if (!authorized(req.headers.authorization, settings.adminPassword)) {
        res.setHeader('WWW-Authenticate', 'Basic realm="Pony Tesla connection test", charset="UTF-8"');
        return json({ error: '需要后台测试账号；账号名为 owner，密码由本地 setup 生成' }, 401);
      }
      if (['POST', 'PATCH', 'PUT', 'DELETE'].includes(req.method) && req.headers.origin !== settings.origin) throw new SafeError('请求来源无效', 403);
      if (req.method === 'GET' && ['/', '/app.js', '/style.css'].includes(url.pathname)) {
        const file = url.pathname === '/' ? 'index.html' : url.pathname.slice(1);
        const types = { 'index.html': 'text/html', 'app.js': 'text/javascript', 'style.css': 'text/css' };
        // Native POST forms need an Origin header for the CSRF check. A document-wide
        // no-referrer policy makes Chromium send Origin: null. Callback responses
        // keep no-referrer so authorization codes never become a Referer header.
        if (file === 'index.html') res.setHeader('Referrer-Policy', 'same-origin');
        res.writeHead(200, { 'Content-Type': `${types[file]}; charset=utf-8` });
        return res.end(await readFile(new URL(`./web/${file}`, import.meta.url)));
      }
      if (url.pathname === '/api/status' && req.method === 'GET') return json({ missing: settings.missing,
        authorized: vault ? Boolean(await vault.read()) : false,
        callback: settings.origin ? `${settings.origin}/oauth/callback` : null });
      if (url.pathname === '/api/readiness' && req.method === 'GET') return json(await readiness(settings, vault, history));
      if (url.pathname.startsWith('/api/v1/')) {
        if (!history) throw new SafeError('历史存储尚未启用', 503);
        if (url.pathname === '/api/v1/history/status' && req.method === 'GET') return json(history.stats());
        if (url.pathname === '/api/v1/trips' && req.method === 'GET') {
          const allowed = ['vin', 'limit', 'before', 'from'];
          if ([...url.searchParams.keys()].some(key => !allowed.includes(key) || url.searchParams.getAll(key).length !== 1)) throw new SafeError('查询参数无效');
          return json(history.list({ vin: url.searchParams.get('vin') ?? undefined,
            limit: url.searchParams.has('limit') ? Number(url.searchParams.get('limit')) : 30,
            before: url.searchParams.get('before') ?? undefined, from: url.searchParams.get('from') ?? undefined }));
        }
        const tripPath = /^\/api\/v1\/trips\/([a-f0-9-]{36})(\/export\.csv)?$/.exec(url.pathname);
        if (tripPath) {
          const id = tripPath[1];
          if (req.method === 'GET') {
            const trip = history.detail(id);
            if (!tripPath[2]) return json({ trip });
            res.writeHead(200, { 'Content-Type': 'text/csv; charset=utf-8', 'Content-Disposition': `attachment; filename="pony-trip-${id}.csv"` });
            return res.end(tripCSV(trip));
          }
          if (!tripPath[2] && req.method === 'PATCH') return json({ trip: history.metadata(id, await readJSON(req)) });
          if (!tripPath[2] && req.method === 'DELETE') { history.deleteTrip(id); return json({ deleted: true }); }
        }
        const snapshotPath = /^\/api\/v1\/vehicles\/([A-HJ-NPR-Z0-9]{17})\/snapshot$/.exec(url.pathname);
        if (snapshotPath && req.method === 'GET') {
          const snapshot = history.snapshot(snapshotPath[1]);
          if (!snapshot) throw new SafeError('暂无缓存车况，请先完成授权并读取车辆', 404);
          return json({ snapshot });
        }
        throw new SafeError('未找到该接口', 404);
      }
      if (url.pathname === '/oauth/start' && req.method === 'POST') {
        if (!client) throw new SafeError('请先完成开发者应用与域名配置', 503);
        const { state, browser } = states.issue();
        res.setHeader('Set-Cookie', `pony_oauth=${browser}; Path=/oauth; HttpOnly; Secure; SameSite=Lax; Max-Age=600`);
        res.writeHead(303, { Location: client.authorizeURL(state) }); return res.end();
      }
      if (url.pathname === '/api/vehicles' && req.method === 'GET') {
        if (!client) throw new SafeError('请先完成开发者应用与域名配置', 503);
        const release = sharedOwnerMode ? acquireFleet() : () => {};
        try { return json({ vehicles: await client.vehicles() }); } finally { release(); }
      }
      if (url.pathname === '/api/probe' && req.method === 'POST') {
        if (!client) throw new SafeError('请先完成开发者应用与域名配置', 503);
        if (probeActive || Date.now() - lastProbe < 15_000) throw new SafeError('请等待至少 15 秒后再读取', 429);
        let size = 0;
        const chunks = [];
        // Preserve the response socket on oversized/chunked requests, then drain the input.
        try {
          for await (const chunk of req.iterator({ destroyOnReturn: false })) {
            size += chunk.length;
            if (size > 1024) throw new SafeError('请求过大', 413);
            chunks.push(chunk);
          }
        } catch (error) { req.resume(); throw error; }
        let parsed;
        try { parsed = JSON.parse(Buffer.concat(chunks).toString('utf8')); } catch { throw new SafeError('请求格式无效'); }
        if (!isRecord(parsed) || !validVin(parsed.vin)) throw new SafeError('请选择有效车辆');
        // Another request may have started probing while this request body was arriving.
        if (probeActive || Date.now() - lastProbe < 15_000) throw new SafeError('请等待至少 15 秒后再读取', 429);
        const release = sharedOwnerMode ? acquireFleet(true) : () => {};
        probeActive = true; lastProbe = Date.now();
        try {
          const result = await client.probe(parsed.vin);
          if (history) history.saveProbe(result);
          return json(result);
        } finally { probeActive = false; release(); }
      }
      throw new SafeError('未找到该接口', 404);
    } catch (e) {
      // Never send upstream bodies, authorization codes, secrets or stack traces to logs/browser.
      json({ error: e instanceof SafeError ? e.message : '后台内部错误，请检查配置与加密存储' }, e instanceof SafeError ? e.status : 500);
    }
  });
  server.on('close', () => nativeRouter.close?.());
  return server;
}

if (process.argv[1] && import.meta.url === pathToFileURL(process.argv[1]).href) {
  const settings = { ...config(), nativeEnabled: process.env.NATIVE_ENABLED === '1',
    ownerPairingEnabled: process.env.OWNER_PAIRING_ENABLED === '1',
    nativeApprovedOrigin: process.env.NATIVE_APPROVED_ORIGIN };
  const vault = settings.key ? new Vault(settings.dir, settings.key) : null;
  const client = settings.missing.length ? null : new TeslaClient(settings, vault);
  const history = new HistoryStore(`${settings.dir}/history.sqlite`);
  const cleanup = setInterval(() => {
    try { history.prune(); } catch { console.error('History cleanup failed; check local storage health.'); }
  }, 3600000);
  cleanup.unref();
  const server = createApp(settings, client, vault, history).listen(settings.port, settings.host, () => {
    console.log(`Connection test listening on ${settings.host}:${settings.port}; ${settings.missing.length ? 'configuration required' : 'awaiting Tesla authorization'}`);
  });
  for (const signal of ['SIGTERM', 'SIGINT']) process.once(signal, () => {
    clearInterval(cleanup);
    server.close(() => { history.close(); process.exit(0); });
    setTimeout(() => process.exit(1), 10000).unref();
  });
}
