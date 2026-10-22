import { DatabaseSync } from 'node:sqlite';
import { mkdirSync, chmodSync, lstatSync, openSync, closeSync } from 'node:fs';
import { dirname, resolve } from 'node:path';
import { createHash, randomUUID } from 'node:crypto';
import { SafeError, validVin, isRecord } from './core.mjs';
import { normalizeSample, RETENTION_MS, MAX_GAP_MS } from './history.mjs';

export { RETENTION_MS };
export const CAPTURE_LIMITS = Object.freeze({ batch: 500, bytes: 524288, eventsPerBinding: 20000, bindings: 1000, bindingTTL: 86400000 });
const fail = (message, status = 400) => { throw new SafeError(message, status); };
const hash = value => createHash('sha256').update(value).digest('hex');
const text = value => typeof value === 'string' && /^[A-Za-z0-9_.:@/-]{1,160}$/.test(value);
const iso = value => new Date(value).toISOString();
function time(value) {
  if (typeof value !== 'string' || !/^\d{4}-\d\d-\d\dT\d\d:\d\d:\d\d(?:\.\d{1,3})?Z$/.test(value)) fail('UTC timestamp required');
  const n = Date.parse(value);
  if (!Number.isFinite(n) || iso(n).slice(0, 19) !== value.slice(0, 19)) fail('Invalid UTC timestamp');
  return n;
}
const number = (n, min, max) => n == null ? null : typeof n === 'number' && Number.isFinite(n) && n >= min && n <= max ? n : fail('Invalid measurement');
const states = ['Charging', 'Starting', 'Stopped', 'Complete', 'Disconnected', 'NoPower', 'unknown'];
const activeCharge = s => ['Charging', 'Starting'].includes(s.charge_state);
const endedCharge = s => ['Stopped', 'Complete', 'Disconnected', 'NoPower'].includes(s.charge_state);
function event(raw, now) {
  if (!isRecord(raw) || !text(raw.id) || !['trip', 'charge'].includes(raw.kind)) fail('Invalid event identity or kind');
  const keys = raw.kind === 'trip' ? ['gear', 'latitude', 'longitude', 'speed_kph', 'power_kw', 'battery_percent', 'odometer_km']
    : ['charge_state', 'charger_type', 'battery_percent', 'energy_added_kwh'];
  if (Object.keys(raw).some(k => !['id', 'kind', 'at', ...keys].includes(k))) fail('Unknown event field');
  const at = time(raw.at);
  if (at > now || at <= now - RETENTION_MS) fail('Event outside retention window');
  if (raw.kind === 'trip') return { id: raw.id, kind: raw.kind, ...normalizeSample(raw), at: iso(at) };
  if (raw.charge_state != null && !states.includes(raw.charge_state)) fail('Invalid charge state');
  if (raw.charger_type != null && !['ac', 'dc', 'unknown'].includes(raw.charger_type)) fail('Invalid charger type');
  return { id: raw.id, kind: raw.kind, at: iso(at), charge_state: raw.charge_state ?? 'unknown', charger_type: raw.charger_type ?? 'unknown',
    battery_percent: number(raw.battery_percent, 0, 100), energy_added_kwh: number(raw.energy_added_kwh, 0, 100000) };
}

// Sparse telemetry is a separate, presence-preserving journal, never a permissive
// alternative to the strict sample validator above. Omission is not invalidity.
function patch(raw, now) {
  if (!isRecord(raw) || !text(raw.id) || raw.kind !== 'trip'
    || Object.keys(raw).some(k => !['id', 'kind', 'at', 'fields'].includes(k)) || !isRecord(raw.fields)) fail('Invalid trip patch');
  const at = time(raw.at);
  if (at > now || at <= now - RETENTION_MS) fail('Event outside retention window');
  const names = Object.keys(raw.fields);
  if (!names.length || names.some(k => !['gear', 'battery_percent'].includes(k))) fail('Invalid patch fields');
  const fields = {};
  for (const name of ['gear', 'battery_percent']) {
    if (!Object.hasOwn(raw.fields, name)) continue;
    const field = raw.fields[name];
    if (!isRecord(field) || typeof field.valid !== 'boolean'
      || Object.keys(field).some(k => !['valid', ...(field.valid ? ['value'] : [])].includes(k))) fail('Invalid field presence');
    if (!field.valid) { fields[name] = { valid: false }; continue; }
    if (name === 'gear' ? !['P', 'D', 'R', 'N', 'unknown'].includes(field.value)
      : typeof field.value !== 'number' || !Number.isFinite(field.value) || field.value < 0 || field.value > 100) fail('Invalid patch value');
    fields[name] = { valid: true, value: field.value };
  }
  return { id: raw.id, kind: 'trip', at: iso(at), fields };
}
function unionFields(left, right) {
  const fields = {};
  for (const name of ['gear', 'battery_percent']) {
    if (left[name] && right[name] && JSON.stringify(left[name]) !== JSON.stringify(right[name])) fail('Conflicting same-time patch field', 409);
    if (left[name] || right[name]) fields[name] = left[name] ?? right[name];
  }
  return fields;
}
function sparsePoints(rows, binding) {
  const grouped = new Map();
  for (const row of rows) {
    const p = JSON.parse(row.payload), fields = unionFields(grouped.get(p.at) ?? {}, p.fields);
    grouped.set(p.at, fields);
  }
  return [...grouped].map(([at, fields]) => ({
    // Identity must not depend on which delivery happened to arrive first.
    id: hash(`${binding}/trip/patch/${at}`), kind: 'trip', at, fields,
    gear: fields.gear?.valid ? fields.gear.value : 'unknown',
    battery_percent: fields.battery_percent?.valid ? fields.battery_percent.value : null,
    latitude: null, longitude: null, speed_kph: null, power_kw: null, odometer_km: null,
  }));
}

// Pure sorted replay. Batch boundaries and wall-clock inactivity NEVER close a record.
function assemble(kind, samples, basis, barriers = [], sparse = false) {
  const result = []; let current = null; let previous = null;
  const finish = reason => { if (current) { current.end_reason = reason; result.push(current); current = null; } };
  for (const sample of samples) {
    const gap = previous && (time(sample.at) - time(previous.at) > MAX_GAP_MS
      || barriers.some(b => b.first <= time(sample.at) && b.last >= time(previous.at)));
    if (sparse && !sample.fields.gear) {
      // Battery traffic neither confirms nor refreshes the state clock.
      if (current && gap) finish('data_gap');
      if (current) current.samples.push(sample);
      continue;
    }
    if (sparse && (!sample.fields.gear.valid || sample.gear === 'unknown')) {
      finish('data_gap'); previous = sample; continue;
    }
    const reset = kind === 'charge' && current && sample.energy_added_kwh != null && current.samples.at(-1).energy_added_kwh != null
      && sample.energy_added_kwh < current.samples.at(-1).energy_added_kwh;
    if (current && (gap || reset)) finish(gap ? 'data_gap' : 'counter_reset');
    const moving = kind === 'trip' ? ['D', 'R'].includes(sample.gear) : activeCharge(sample);
    if (!current && moving) {
      const observedStart = !gap && previous && (kind === 'trip' ? previous.gear === 'P' : endedCharge(previous)) && !reset;
      current = { kind, start: observedStart ? sample.at : null, first_observed_at: sample.at, end: null,
        start_observed: !!observedStart, end_reason: 'in_progress', samples: [] };
    }
    if (current) {
      current.samples.push(sample);
      if (kind === 'trip' ? sample.gear === 'P' : endedCharge(sample)) { current.end = sample.at; finish(kind === 'trip' ? 'parked' : sample.charge_state); }
    }
    previous = sample;
  }
  finish('in_progress');
  return result.map(record => {
    const points = record.samples, first = points[0], last = points.at(-1);
    const complete = record.start_observed && record.end !== null && !['counter_reset', 'data_gap'].includes(record.end_reason);
    const common = { ...record, last_observed_at: last.at, complete, cost: null, cost_currency: null };
    if (kind === 'charge') {
      const counters = points.map(s => s.energy_added_kwh);
      const measured = counters.length > 1 && counters.every(n => n !== null) && counters.every((n, i) => !i || n >= counters[i - 1]);
      const types = [...new Set(points.map(s => s.charger_type).filter(t => t !== 'unknown'))];
      return { ...common, charger_type: types.length === 1 ? types[0] : 'unknown', energy_added_kwh: measured ? counters.at(-1) - counters[0] : null,
        energy_basis: basis, energy_method: measured ? 'observed_session_counter_delta' : 'insufficient_data' };
    }
    const odo = points.map(s => s.odometer_km);
    const distance = odo.length > 1 && odo.every(n => n !== null) && odo.every((n, i) => !i || n >= odo[i - 1]) ? odo.at(-1) - odo[0] : null;
    let energy = 0;
    const measured = points.length > 1 && points.every(s => s.power_kw !== null);
    if (measured) for (let i = 1; i < points.length; i++) energy += (points[i - 1].power_kw + points[i].power_kw) / 2 * (time(points[i].at) - time(points[i - 1].at)) / 3600000;
    return { ...common, distance_km: distance, net_energy_kwh: measured ? energy : null, energy_method: measured ? 'trapezoid_power_estimate' : 'insufficient_data' };
  });
}

/** Local persistence only. All three validators are trusted synchronous integration seams,
 * NOT validators for self-asserted HTTP fields. Missing seams deny access. */
export class NativeCaptureStore {
  constructor(path, { clock = Date.now, allowSimulation = false, authenticateAccount = () => null,
    authorizeOperator = () => false, authenticateReceiver = () => null } = {}) {
    this.clock = clock; this.allowSimulation = allowSimulation;
    this.authenticateAccount = authenticateAccount; this.authorizeOperator = authorizeOperator; this.authenticateReceiver = authenticateReceiver;
    if (path !== ':memory:') {
      // Deployment must also prevent concurrent hostile writers in the private directory.
      let component = resolve(path);
      while (true) {
        try {
          const info = lstatSync(component);
          if (info.isSymbolicLink() || (component === resolve(path) ? !info.isFile() : !info.isDirectory())) fail('Unsafe capture database path');
        } catch (e) { if (e.code !== 'ENOENT') throw e; }
        const parent = dirname(component); if (parent === component) break; component = parent;
      }
      mkdirSync(dirname(path), { recursive: true, mode: 0o700 });
      // Set private permissions at creation, rather than relying on a later chmod window.
      try { closeSync(openSync(path, 'wx', 0o600)); } catch (e) { if (e.code !== 'EEXIST') throw e; }
    }
    this.db = new DatabaseSync(path);
    // Refuse any existing SQLite database not explicitly marked as this isolated store.
    const app = this.db.prepare('PRAGMA application_id').get().application_id;
    const tables = this.db.prepare("SELECT name FROM sqlite_master WHERE type='table'").all();
    if ((app !== 0 && app !== 1347309379) || (app === 0 && tables.length)) { this.db.close(); fail('Not a native capture database'); }
    if (this.db.prepare('PRAGMA user_version').get().user_version > 2) { this.db.close(); fail('Unsupported capture schema'); }
    if (path !== ':memory:') { chmodSync(dirname(path), 0o700); chmodSync(path, 0o600); }
    this.db.exec(`PRAGMA application_id=1347309379; PRAGMA journal_mode=DELETE;
      PRAGMA synchronous=FULL; PRAGMA secure_delete=ON; PRAGMA busy_timeout=5000;
      CREATE TABLE IF NOT EXISTS bindings(id TEXT PRIMARY KEY, account TEXT NOT NULL, vin TEXT NOT NULL, source TEXT NOT NULL,
        stream TEXT NOT NULL, basis TEXT NOT NULL, expires INTEGER NOT NULL, revoked INTEGER NOT NULL DEFAULT 0, floor INTEGER NOT NULL DEFAULT 0);
      CREATE TABLE IF NOT EXISTS events(binding TEXT NOT NULL, id TEXT NOT NULL, at INTEGER NOT NULL, kind TEXT NOT NULL, payload TEXT NOT NULL, PRIMARY KEY(binding,id));
      CREATE INDEX IF NOT EXISTS events_time ON events(binding,at,id);
      CREATE TABLE IF NOT EXISTS records(id TEXT PRIMARY KEY, binding TEXT NOT NULL, account TEXT NOT NULL, vin TEXT NOT NULL, kind TEXT NOT NULL,
        observed INTEGER NOT NULL, payload TEXT NOT NULL, revision INTEGER NOT NULL, tag TEXT NOT NULL DEFAULT '', note TEXT NOT NULL DEFAULT '');
      CREATE INDEX IF NOT EXISTS records_owner ON records(account,vin,observed,id);
      CREATE TABLE IF NOT EXISTS patches(binding TEXT NOT NULL, id TEXT NOT NULL, at INTEGER NOT NULL, payload TEXT NOT NULL, PRIMARY KEY(binding,id));
      CREATE INDEX IF NOT EXISTS patches_time ON patches(binding,at,id);
      CREATE TABLE IF NOT EXISTS suppressed(binding TEXT NOT NULL, kind TEXT NOT NULL, first INTEGER NOT NULL, last INTEGER NOT NULL, expires INTEGER NOT NULL);
    `);
    // v0/v1 gain an empty isolated journal; existing strict rows are untouched.
    // Set the version only after every schema statement has succeeded.
    this.db.exec('PRAGMA user_version=2');
    this.prune(); this.recover();
  }
  close() { this.db.close(); }
  transaction(action) {
    this.db.exec('BEGIN IMMEDIATE');
    try { const result = action(); this.db.exec('COMMIT'); return result; } catch (e) { this.db.exec('ROLLBACK'); throw e; }
  }
  account(context, vin) {
    // Validator must revalidate the native session and current VIN membership on every call.
    const account = this.authenticateAccount(context, vin);
    if (!text(account)) fail('Authenticated account required', 401);
    return account;
  }
  operator(context) { if (this.authorizeOperator(context) !== true) fail('Trusted operator required', 403); }
  register(context, { account, vin, source = 'telemetry', stream, expires_at, energy_basis = 'battery_session_counter' } = {}) {
    this.operator(context); this.prune();
    const expires = time(expires_at);
    if (!text(account) || !validVin(vin) || !text(stream) || !['telemetry', 'simulation'].includes(source)
      || !['battery_session_counter', 'ac_charger_session_counter', 'dc_charger_session_counter'].includes(energy_basis)
      || expires <= this.clock() || expires > this.clock() + CAPTURE_LIMITS.bindingTTL) fail('Invalid capture binding');
    if (source === 'simulation' && !this.allowSimulation) fail('Real store refuses simulation', 403);
    return this.transaction(() => {
      if (this.db.prepare('SELECT id FROM bindings WHERE vin=? AND stream=? AND source=? AND revoked=0 AND expires>?').get(vin, stream, source, this.clock())) fail('Stream already bound; revoke first', 409);
      const prior = this.db.prepare('SELECT * FROM bindings WHERE account=? AND vin=? AND source=? AND stream=? ORDER BY expires DESC LIMIT 1').get(account, vin, source, stream);
      if (prior) {
        if (prior.basis !== energy_basis) fail('Counter measurement basis cannot change within a binding', 409);
        this.db.prepare('UPDATE bindings SET expires=?,revoked=0 WHERE id=?').run(expires, prior.id);
        return { binding_id: prior.id, expires_at: iso(expires) };
      }
      if (this.db.prepare('SELECT count(*) AS n FROM bindings').get().n >= CAPTURE_LIMITS.bindings) fail('Binding capacity exceeded', 429);
      const id = randomUUID();
      const floor = this.db.prepare('SELECT MAX(floor) AS n FROM bindings WHERE account=? AND vin=?').get(account, vin).n ?? 0;
      this.db.prepare('INSERT INTO bindings(id,account,vin,source,stream,basis,expires,floor) VALUES(?,?,?,?,?,?,?,?)').run(id, account, vin, source, stream, energy_basis, expires, floor);
      return { binding_id: id, expires_at: iso(expires) };
    });
  }
  revoke(context, bindingID) {
    const binding = this.db.prepare('SELECT * FROM bindings WHERE id=?').get(bindingID);
    if (!binding) fail('Binding not found', 404);
    const account = this.account(context, binding.vin);
    if (binding.account !== account) fail('Binding not found', 404);
    this.db.prepare('UPDATE bindings SET revoked=1,floor=MAX(floor,?) WHERE id=?').run(this.clock(), bindingID);
    return { revoked: true, history_preserved: true };
  }
  ingest(receiverContext, bindingID, input) {
    this.prune();
    const identity = this.authenticateReceiver(receiverContext);
    if (!isRecord(identity) || !validVin(identity.vin) || !text(identity.stream)) fail('Authenticated upstream receiver required', 401);
    if (!Array.isArray(input) || !input.length || input.length > CAPTURE_LIMITS.batch) fail('Invalid event batch');
    let size; try { size = Buffer.byteLength(JSON.stringify(input)); } catch { fail('Invalid event batch'); }
    if (size > CAPTURE_LIMITS.bytes) fail('Event batch too large', 413);
    const normalized = input.map(raw => event(raw, this.clock()));
    // Journal commit is deliberately separate from replay: crash after commit is recoverable.
    const result = this.transaction(() => {
      const b = this.db.prepare('SELECT * FROM bindings WHERE id=?').get(bindingID);
      if (!b || b.revoked || b.expires <= this.clock() || b.vin !== identity.vin || b.stream !== identity.stream) fail('Binding unavailable', 403);
      if (b.source === 'simulation' && !this.allowSimulation) fail('Real store refuses simulation', 403);
      if (normalized.some(s => s.kind === 'trip') && this.db.prepare('SELECT 1 FROM patches WHERE binding=?').get(b.id)) fail('Cannot mix strict trips and sparse patches in a binding', 409);
      let inserted = 0, duplicates = 0, suppressed = 0;
      for (const s of normalized) {
        const at = time(s.at), payload = JSON.stringify(s);
        const old = this.db.prepare('SELECT payload FROM events WHERE binding=? AND id=?').get(b.id, s.id);
        if (old) { if (old.payload !== payload) fail('Conflicting event identity', 409); duplicates++; continue; }
        if (at <= b.floor || this.db.prepare('SELECT 1 FROM suppressed s JOIN bindings owner ON owner.id=s.binding WHERE owner.account=? AND owner.vin=? AND s.kind=? AND s.first<=? AND s.last>=?').get(b.account, b.vin, s.kind, at, at)) { suppressed++; continue; }
        const sameTime = this.db.prepare('SELECT payload FROM events WHERE binding=? AND kind=? AND at=?').get(b.id, s.kind, at);
        if (sameTime) fail('Ambiguous same-time event; dispatcher must coalesce fields', 409);
        this.db.prepare('INSERT INTO events VALUES(?,?,?,?,?)').run(b.id, s.id, at, s.kind, payload); inserted++;
      }
      if (this.db.prepare('SELECT (SELECT count(*) FROM events WHERE binding=?) + (SELECT count(*) FROM patches WHERE binding=?) AS n').get(b.id, b.id).n > CAPTURE_LIMITS.eventsPerBinding) fail('Journal capacity exceeded', 429);
      return { inserted, duplicates, suppressed };
    });
    this.replay(bindingID);
    return { ...result, durable: true };
  }
  ingestPatches(receiverContext, bindingID, input) {
    this.prune();
    const identity = this.authenticateReceiver(receiverContext);
    if (!isRecord(identity) || !validVin(identity.vin) || !text(identity.stream)) fail('Authenticated upstream receiver required', 401);
    if (!Array.isArray(input) || !input.length || input.length > CAPTURE_LIMITS.batch) fail('Invalid patch batch');
    let size; try { size = Buffer.byteLength(JSON.stringify(input)); } catch { fail('Invalid patch batch'); }
    if (size > CAPTURE_LIMITS.bytes) fail('Patch batch too large', 413);
    const normalized = input.map(raw => patch(raw, this.clock()));
    const result = this.transaction(() => {
      const b = this.db.prepare('SELECT * FROM bindings WHERE id=?').get(bindingID);
      if (!b || b.revoked || b.expires <= this.clock() || b.vin !== identity.vin || b.stream !== identity.stream) fail('Binding unavailable', 403);
      if (b.source === 'simulation' && !this.allowSimulation) fail('Real store refuses simulation', 403);
      if (this.db.prepare("SELECT 1 FROM events WHERE binding=? AND kind='trip'").get(b.id)) fail('Cannot mix strict trips and sparse patches in a binding', 409);
      let inserted = 0, duplicates = 0, suppressed = 0;
      for (const p of normalized) {
        const at = time(p.at);
        if (at <= b.floor || this.db.prepare("SELECT 1 FROM suppressed s JOIN bindings owner ON owner.id=s.binding WHERE owner.account=? AND owner.vin=? AND s.kind='trip' AND s.first<=? AND s.last>=?").get(b.account, b.vin, at, at)) { suppressed++; continue; }
        const old = this.db.prepare('SELECT at,payload FROM patches WHERE binding=? AND id=?').get(b.id, p.id);
        if (old && old.at !== at) fail('Conflicting patch identity', 409);
        const peers = this.db.prepare('SELECT payload FROM patches WHERE binding=? AND at=?').all(b.id, at);
        let fields = p.fields;
        for (const peer of peers) fields = unionFields(fields, JSON.parse(peer.payload).fields);
        // Validate against every same-time peer, but retain only this identity's presence.
        const payload = JSON.stringify({ ...p, fields: unionFields(old ? JSON.parse(old.payload).fields : {}, p.fields) });
        if (old?.payload === payload) { duplicates++; continue; }
        this.db.prepare('INSERT INTO patches VALUES(?,?,?,?) ON CONFLICT(binding,id) DO UPDATE SET payload=excluded.payload').run(b.id, p.id, at, payload);
        inserted++;
      }
      if (this.db.prepare('SELECT (SELECT count(*) FROM events WHERE binding=?) + (SELECT count(*) FROM patches WHERE binding=?) AS n').get(b.id, b.id).n > CAPTURE_LIMITS.eventsPerBinding) fail('Journal capacity exceeded', 429);
      return { inserted, duplicates, suppressed };
    });
    this.replay(bindingID);
    return { ...result, durable: true };
  }
  recover() { for (const b of this.db.prepare('SELECT id FROM bindings').all()) this.replay(b.id); }
  replay(bindingID, inTransaction = false) {
    const action = () => {
      const b = this.db.prepare('SELECT * FROM bindings WHERE id=?').get(bindingID);
      if (!b) return;
      const old = this.db.prepare('SELECT * FROM records WHERE binding=?').all(b.id).map(r => ({ ...r, data: JSON.parse(r.payload) }));
      const used = new Set();
      for (const kind of ['trip', 'charge']) {
        let points = this.db.prepare('SELECT payload FROM events WHERE binding=? AND kind=? ORDER BY at,id').all(b.id, kind).map(r => JSON.parse(r.payload));
        const sparse = kind === 'trip' && !!this.db.prepare('SELECT 1 FROM patches WHERE binding=?').get(b.id);
        if (sparse) points = sparsePoints(this.db.prepare('SELECT payload FROM patches WHERE binding=? ORDER BY at,id').all(b.id), b.id);
        const barriers = this.db.prepare('SELECT s.first,s.last FROM suppressed s JOIN bindings owner ON owner.id=s.binding WHERE owner.account=? AND owner.vin=? AND s.kind=?').all(b.account, b.vin, kind);
        for (const record of assemble(kind, points, b.basis, barriers, sparse)) {
          const first = time(record.first_observed_at), last = time(record.last_observed_at);
          if (this.db.prepare('SELECT 1 FROM suppressed s JOIN bindings owner ON owner.id=s.binding WHERE owner.account=? AND owner.vin=? AND s.kind=? AND s.first<=? AND s.last>=?').get(b.account, b.vin, kind, last, first)) continue;
          const ids = new Set(record.samples.map(s => s.id));
          const matches = old.filter(r => r.kind === kind && !used.has(r.id) && r.data.samples.some(s => ids.has(s.id))).sort((a, z) => a.id.localeCompare(z.id));
          const prior = matches[0];
          const id = prior?.id ?? hash(`${b.account}/${b.vin}/${b.source}/${b.id}/${kind}/${record.samples[0].id}`);
          used.add(id);
          const payload = JSON.stringify({ ...record, id, vin: b.vin, source: b.source });
          if (prior) this.db.prepare('UPDATE records SET observed=?, payload=?, revision=revision+? WHERE id=?').run(last, payload, prior.payload === payload ? 0 : 1, id);
          else this.db.prepare('INSERT INTO records(id,binding,account,vin,kind,observed,payload,revision) VALUES(?,?,?,?,?,?,?,1)').run(id, b.id, b.account, b.vin, kind, last, payload);
          // On a late bridge preserve annotations from every merged interval, rather than silently discarding them.
          if (matches.length > 1) {
            const tags = [...new Set(matches.map(r => r.tag).filter(Boolean))].join(' / ');
            const notes = [...new Set(matches.map(r => r.note).filter(Boolean))].join('\n');
            this.db.prepare('UPDATE records SET tag=?,note=? WHERE id=?').run(tags, notes, id);
          }
        }
      }
      for (const r of old) if (!used.has(r.id)) this.db.prepare('DELETE FROM records WHERE id=?').run(r.id);
    };
    return inTransaction ? action() : this.transaction(action);
  }
  prune() {
    const cutoff = this.clock() - RETENTION_MS;
    return this.transaction(() => {
      const events = this.db.prepare('DELETE FROM events WHERE at<=?').run(cutoff).changes;
      const patches = this.db.prepare('DELETE FROM patches WHERE at<=?').run(cutoff).changes;
      // Drop whole records that contain expired raw data; replay may rebuild only the retained, incomplete tail.
      const records = this.db.prepare("DELETE FROM records WHERE observed<=? OR json_extract(payload,'$.first_observed_at')<=?").run(cutoff, iso(cutoff)).changes;
      this.db.prepare('DELETE FROM suppressed WHERE expires<=?').run(this.clock());
      this.db.prepare('DELETE FROM bindings WHERE expires<=? AND id NOT IN (SELECT binding FROM events) AND id NOT IN (SELECT binding FROM patches) AND id NOT IN (SELECT binding FROM records) AND id NOT IN (SELECT binding FROM suppressed)').run(cutoff);
      return { events, patches, records, retention_hours: 168 };
    });
  }
  list(context, { vin, kind, limit = 30, before } = {}) {
    const account = this.account(context, vin); this.prune();
    if (!validVin(vin) || (kind !== undefined && !['trip', 'charge'].includes(kind)) || !Number.isInteger(limit) || limit < 1 || limit > 100) fail('Invalid record query');
    let cursor = null;
    if (before !== undefined) {
      if (typeof before !== 'string' || before.length > 1024) fail('Invalid cursor');
      try { cursor = JSON.parse(Buffer.from(before, 'base64url').toString()); } catch { fail('Invalid cursor'); }
      if (!isRecord(cursor) || cursor.scope !== hash(`${account}/${vin}/${kind ?? ''}`) || !Number.isSafeInteger(cursor.at) || !/^[a-f0-9]{64}$/.test(cursor.id)) fail('Invalid cursor');
    }
    const rows = this.db.prepare(`SELECT * FROM records WHERE account=? AND vin=? AND (? IS NULL OR kind=?)
      AND (? IS NULL OR observed<? OR (observed=? AND id<?)) ORDER BY observed DESC,id DESC LIMIT ?`).all(account, vin, kind ?? null, kind ?? null,
      cursor?.at ?? null, cursor?.at ?? null, cursor?.at ?? null, cursor?.id ?? null, limit + 1);
    const more = rows.length > limit; rows.length = Math.min(rows.length, limit); const last = rows.at(-1);
    return { records: rows.map(row => { const { samples, ...r } = JSON.parse(row.payload); return { ...r, sample_count: samples.length, revision: row.revision, tag: row.tag, note: row.note }; }),
      next_cursor: more ? Buffer.from(JSON.stringify({ scope: hash(`${account}/${vin}/${kind ?? ''}`), at: last.observed, id: last.id })).toString('base64url') : null,
      retention_hours: 168, source_policy: this.allowSimulation ? 'telemetry_and_simulation' : 'telemetry_only' };
  }
  detail(context, vin, id) {
    const account = this.account(context, vin); this.prune();
    if (!validVin(vin) || typeof id !== 'string' || !/^[a-f0-9]{64}$/.test(id)) fail('Invalid record identity');
    const row = this.db.prepare('SELECT * FROM records WHERE account=? AND vin=? AND id=?').get(account, vin, id);
    if (!row) fail('Record not found', 404);
    return { ...JSON.parse(row.payload), revision: row.revision, tag: row.tag, note: row.note, retention_hours: 168 };
  }
  annotate(context, vin, id, input) {
    this.detail(context, vin, id);
    if (!isRecord(input) || Object.keys(input).some(k => !['tag', 'note'].includes(k)) || typeof input.tag !== 'string' || typeof input.note !== 'string'
      || [...input.tag].length > 30 || [...input.note].length > 500 || /[\u0000-\u0008\u000b\u000c\u000e-\u001f]/.test(input.tag + input.note)) fail('Invalid annotations (tag 30, note 500 characters)');
    this.db.prepare('UPDATE records SET tag=?,note=?,revision=revision+1 WHERE id=?').run(input.tag, input.note, id);
    return this.detail(context, vin, id);
  }
  deleteRecord(context, vin, id) {
    const record = this.detail(context, vin, id);
    const touched = [];
    const result = this.transaction(() => {
      const row = this.db.prepare('SELECT binding FROM records WHERE id=?').get(id);
      const first = time(record.first_observed_at), last = time(record.last_observed_at);
      // Suppress only this observed interval, never the gap to an adjacent session.
      this.db.prepare('INSERT INTO suppressed VALUES(?,?,?,?,?)').run(row.binding, record.kind, first, last, this.clock() + RETENTION_MS);
      const owner = this.db.prepare('SELECT account,vin FROM bindings WHERE id=?').get(row.binding);
      for (const b of this.db.prepare('SELECT id FROM bindings WHERE account=? AND vin=?').all(owner.account, owner.vin)) {
        touched.push(b.id);
        this.db.prepare('DELETE FROM events WHERE binding=? AND kind=? AND at>=? AND at<=?').run(b.id, record.kind, first, last);
        if (record.kind === 'trip') this.db.prepare('DELETE FROM patches WHERE binding=? AND at>=? AND at<=?').run(b.id, first, last);
        this.db.prepare("DELETE FROM records WHERE binding=? AND kind=? AND observed>=? AND json_extract(payload,'$.first_observed_at')<=?").run(b.id, record.kind, first, iso(last));
      }
      for (const binding of touched) this.replay(binding, true);
      return { deleted: true };
    });
    return result;
  }
  deleteAll(context, vin) {
    const account = this.account(context, vin); if (!validVin(vin)) fail('Invalid VIN');
    return this.transaction(() => {
      for (const b of this.db.prepare('SELECT id FROM bindings WHERE account=? AND vin=?').all(account, vin)) {
        this.db.prepare('UPDATE bindings SET floor=MAX(floor,?) WHERE id=?').run(this.clock(), b.id);
        this.db.prepare('DELETE FROM events WHERE binding=?').run(b.id);
        this.db.prepare('DELETE FROM patches WHERE binding=?').run(b.id);
      }
      const deleted = this.db.prepare('DELETE FROM records WHERE account=? AND vin=?').run(account, vin).changes;
      return { deleted, replay_suppressed_through: iso(this.clock()) };
    });
  }
  exportCSV(context, vin, id) { return captureCSV(this.detail(context, vin, id)); }
}

export function captureCSV(record) {
  const cell = value => {
    let s = value == null ? '' : String(value);
    if (typeof value === 'string' && /^[\s]*[=+@\-]/u.test(s)) s = `'${s}`;
    return `"${s.replaceAll('"', '""')}"`;
  };
  const fields = record.kind === 'trip' ? ['gear', 'latitude', 'longitude', 'speed_kph', 'power_kw', 'battery_percent', 'odometer_km']
    : ['charge_state', 'charger_type', 'battery_percent', 'energy_added_kwh'];
  const metadata = ['energy_basis', 'start', 'end', 'first_observed_at', 'last_observed_at', 'start_observed', 'complete', 'end_reason', 'energy_method'];
  const rows = [['source', 'kind', 'record_id', 'event_id', 'time_utc', ...metadata, 'record_revision', ...fields, 'tag', 'note'],
    ...record.samples.map(s => [record.source, record.kind, record.id, s.id, s.at, ...metadata.map(key => record[key]), record.revision, ...fields.map(f => s[f]), record.tag, record.note])];
  return '\uFEFF' + rows.map(r => r.map(cell).join(',')).join('\r\n') + '\r\n';
}
