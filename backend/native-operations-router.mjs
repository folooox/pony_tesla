import { randomBytes, createHash } from 'node:crypto';
import { SafeError, isRecord } from './core.mjs';
import { normalizeAction } from './native-commands.mjs';

const VIN = '[A-HJ-NPR-Z0-9]{17}', ID = '[a-f0-9]{64}', COMMAND_ID = '[a-z0-9]+_[A-Za-z0-9_-]{32}';
const fail = (message, status = 400) => { throw new SafeError(message, status); };
const exact = (value, keys) => {
  if (!isRecord(value) || Object.keys(value).length !== keys.length || keys.some(k => !Object.hasOwn(value, k))) fail('Invalid operation fields');
};

/** Optional leaf router. No HTTP-provided identity is ever passed to capture. */
export function createNativeOperationsRouter({ factory, readBody, clock = Date.now }) {
  const instances = new Map(), proofs = new WeakMap(), selections = new Map();
  const authenticateAccount = (proof, vin) => {
    const entry = proofs.get(proof);
    if (!entry || (vin !== undefined && vin !== entry.vin)) return null;
    // Recheck session validity synchronously; membership was freshly checked under the account admission lock.
    try { const session = entry.authenticate(); return session.account === entry.account && session.family === entry.family ? session.account : null; }
    catch { return null; }
  };
  function operations(account) {
    if (!instances.has(account)) instances.set(account, factory(account, { authenticateAccount }) ?? {});
    return instances.get(account);
  }
  function features(account) {
    const ops = operations(account);
    const history = ops.ready?.history === true && ['list', 'detail', 'annotate', 'deleteRecord', 'deleteAll', 'exportCSV'].every(k => typeof ops.capture?.[k] === 'function');
    let commands = ops.ready?.commands === true && ['ready', 'prepare', 'execute', 'status', 'confirm'].every(k => typeof ops.commands?.[k] === 'function');
    if (commands) { try { ops.commands.ready(); } catch { commands = false; } }
    return { trips: history, charge_history: history, commands, telemetry: false };
  }
  function match(method, path) {
    let m = new RegExp(`^/vehicles/(${VIN})/history(?:/(${ID})(/export\\.csv)?)?$`).exec(path);
    if (m && (m[3] ? method === 'GET' : m[2] ? ['GET', 'PATCH', 'DELETE'].includes(method) : ['GET', 'DELETE'].includes(method))) return { type: 'history', vin: m[1], id: m[2], csv: !!m[3] };
    m = new RegExp(`^/vehicles/(${VIN})/commands/(context|prepare)$`).exec(path);
    if (m && method === 'POST') return { type: m[2], vin: m[1] };
    if (path === '/commands/execute' && method === 'POST') return { type: 'execute' };
    m = new RegExp(`^/commands/(${COMMAND_ID})(/confirm)?$`).exec(path);
    if (m && method === (m[2] ? 'POST' : 'GET')) return { type: m[2] ? 'confirm' : 'status', id: m[1] };
    return null;
  }
  async function validate(req, url, route) {
    const query = url.searchParams;
    if (route.type === 'history' && !route.id && req.method === 'GET') {
      if ([...query.keys()].some(k => !['kind', 'limit', 'before'].includes(k) || query.getAll(k).length !== 1)) fail('Invalid history query');
      const kind = query.get('kind') ?? undefined, limit = query.has('limit') ? Number(query.get('limit')) : 30, before = query.get('before') ?? undefined;
      if ((kind !== undefined && !['trip', 'charge'].includes(kind)) || (query.has('limit') && !/^[1-9][0-9]?$|^100$/.test(query.get('limit'))) || !Number.isInteger(limit) || limit > 100
        || (before !== undefined && (!/^[A-Za-z0-9_-]+$/.test(before) || before.length > 1024))) fail('Invalid history query');
      route.query = { vin: route.vin, kind, limit, before };
      if (before !== undefined) {
        try { route.cursor = JSON.parse(Buffer.from(before, 'base64url').toString('utf8')); } catch { fail('Invalid cursor'); }
        if (!isRecord(route.cursor) || Object.keys(route.cursor).sort().join(',') !== 'at,id,scope' || !Number.isSafeInteger(route.cursor.at) || !/^[a-f0-9]{64}$/.test(route.cursor.id) || !/^[a-f0-9]{64}$/.test(route.cursor.scope)) fail('Invalid cursor');
      }
    } else if (url.search) fail('Query parameters not accepted');
    if (!['GET'].includes(req.method)) {
      const input = await readBody(req); route.input = input;
      if (req.method === 'DELETE') { exact(input, ['confirm']); if (input.confirm !== true) fail('Explicit deletion confirmation required'); }
      else if (req.method === 'PATCH') {
        exact(input, ['tag', 'note']);
        if (typeof input.tag !== 'string' || typeof input.note !== 'string' || [...input.tag].length > 30 || [...input.note].length > 500 || /[\u0000-\u0008\u000b\u000c\u000e-\u001f]/.test(input.tag + input.note)) fail('Invalid annotations');
      } else if (route.type === 'context') exact(input, []);
      else {
        exact(input, route.type === 'prepare' ? ['action', 'context'] : route.type === 'execute' ? ['intentId', 'requestId', 'action', 'context'] : ['context']);
        if (typeof input.context !== 'string' || !/^[A-Za-z0-9_-]{43}$/.test(input.context)) fail('Invalid selection context');
        if (input.action) input.action = normalizeAction(input.action);
        if (route.type === 'execute' && (input.intentId !== input.requestId || !new RegExp(`^${COMMAND_ID}$`).test(input.intentId))) fail('Invalid command intent');
      }
    }
  }
  function sweepSelections() {
    const now = clock();
    for (const [family, selection] of selections) {
      // A backwards clock jump must not extend a selection's authority.
      if (now < selection.created || now >= selection.expires) invalidate(family);
    }
  }
  function resolve(session, route) {
    sweepSelections();
    const ops = operations(session.account), flags = features(session.account);
    if (route.cursor && route.cursor.scope !== createHash('sha256').update(`${session.account}/${route.vin}/${route.query.kind ?? ''}`).digest('hex')) fail('Invalid cursor');
    if (!(route.type === 'history' ? flags.trips : flags.commands)) fail('Native route not found', 404);
    if (!['history', 'context'].includes(route.type)) {
      const selection = selections.get(session.family);
      if (!selection || (route.input && selection.context !== route.input.context) || (route.vin && selection.vin !== route.vin)) fail('Selection context expired', 409);
      route.vin = selection.vin; route.context = selection.context;
    }
    return ops;
  }
  async function handle(req, res, route, session, ops, authenticate, json) {
    if (route.type === 'history') {
      const proof = Object.freeze({}); proofs.set(proof, { account: session.account, family: session.family, vin: route.vin, authenticate });
      try {
        const c = ops.capture; let value;
        if (route.csv) {
          const csv = await c.exportCSV(proof, route.vin, route.id);
          res.writeHead(200, { 'Content-Type': 'text/csv; charset=utf-8', 'Content-Disposition': 'attachment; filename="pony-history.csv"' }); res.end(csv); return;
        }
        if (req.method === 'PATCH') value = await c.annotate(proof, route.vin, route.id, route.input);
        else if (req.method === 'DELETE') value = route.id ? await c.deleteRecord(proof, route.vin, route.id) : await c.deleteAll(proof, route.vin);
        else value = route.id ? await c.detail(proof, route.vin, route.id) : await c.list(proof, route.query);
        json(value);
      } finally { proofs.delete(proof); }
      return;
    }
    if (route.type === 'context') {
      sweepSelections();
      invalidate(session.family);
      if (selections.size >= 1000) fail('Selection capacity reached', 429);
      const context = randomBytes(32).toString('base64url');
      const now = clock();
      selections.set(session.family, { account: session.account, vin: route.vin, context, created: now, expires: now + 3600_000, commands: ops.commands });
      json({ context, vin: route.vin, expires_in: 3600 }); return;
    }
    const params = { account: session.account, vin: route.vin, context: route.context };
    if (route.type === 'prepare' || route.type === 'execute') Object.assign(params, route.input);
    else params.operationId = route.id;
    json(await ops.commands[route.type](params));
  }
  function invalidate(family) {
    const old = selections.get(family);
    if (old) { old.commands.store?.invalidateContext(old.account, old.context); selections.delete(family); }
  }
  // Lifecycle of injected stores belongs to the factory owner, including shared stores.
  return { match, validate, resolve, handle, features, invalidate };
}
