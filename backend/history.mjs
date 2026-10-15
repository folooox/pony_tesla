import { DatabaseSync } from 'node:sqlite';
import { mkdirSync, chmodSync } from 'node:fs';
import { dirname } from 'node:path';
import { createHash } from 'node:crypto';
import { SafeError, isRecord, validVin } from './core.mjs';

export const RETENTION_MS = 7 * 24 * 60 * 60 * 1000;
export const MAX_GAP_MS = 120_000;
const MAX_TRIP_MS = 24 * 60 * 60 * 1000;
const sourceValues = new Set(['telemetry', 'simulation']);
const optionalNumber = (value, min, max) => value == null ? null
  : typeof value === 'number' && Number.isFinite(value) && value >= min && value <= max ? value
  : (() => { throw new SafeError('采样数值无效'); })();
const iso = value => new Date(value).toISOString();
function timestamp(value) {
  if (typeof value !== 'string' || !/^\d{4}-\d\d-\d\dT.*Z$/.test(value) || !Number.isFinite(Date.parse(value))) throw new SafeError('时间必须是 UTC ISO 8601 格式');
  return Date.parse(value);
}
export function normalizeSample(raw) {
  if (!isRecord(raw)) throw new SafeError('采样格式无效');
  if (raw.gear != null && !['P', 'D', 'R', 'N'].includes(raw.gear)) throw new SafeError('挡位无效');
  const latitude = optionalNumber(raw.latitude, -90, 90);
  const longitude = optionalNumber(raw.longitude, -180, 180);
  if ((latitude === null) !== (longitude === null)) throw new SafeError('坐标需要同时提供经纬度');
  return { at: iso(timestamp(raw.at)), gear: raw.gear ?? null, latitude, longitude,
    speed_kph: optionalNumber(raw.speed_kph, 0, 400), power_kw: optionalNumber(raw.power_kw, -1000, 2000),
    battery_percent: optionalNumber(raw.battery_percent, 0, 100), odometer_km: optionalNumber(raw.odometer_km, 0, 10_000_000) };
}
function tripID(vin, source, start) {
  const hex = createHash('sha256').update(`${vin}/${source}/${start}`).digest('hex');
  return `${hex.slice(0, 8)}-${hex.slice(8, 12)}-5${hex.slice(13, 16)}-a${hex.slice(17, 20)}-${hex.slice(20, 32)}`;
}
function summarize(samples) {
  let completePower = samples.length > 1;
  let energy = 0;
  let gaps = 0;
  for (let i = 1; i < samples.length; i++) {
    const a = samples[i - 1], b = samples[i];
    const delta = Date.parse(b.at) - Date.parse(a.at);
    if (delta > MAX_GAP_MS) gaps++;
    if (a.power_kw === null || b.power_kw === null || delta > MAX_GAP_MS) completePower = false;
    else energy += (a.power_kw + b.power_kw) / 2 * delta / 3_600_000;
  }
  const first = samples[0], last = samples.at(-1);
  const distance = first.odometer_km !== null && last.odometer_km !== null && last.odometer_km >= first.odometer_km
    && samples.filter(s => s.odometer_km !== null).every((s, i, all) => i === 0 || s.odometer_km >= all[i - 1].odometer_km)
    ? last.odometer_km - first.odometer_km : null;
  return { distance_km: distance, net_energy_kwh: completePower ? energy : null,
    energy_method: completePower ? 'trapezoid_power_estimate' : 'insufficient_data', gap_count: gaps };
}

// Offline batch assembler for validating normalized input. Not a Tesla receiver.
// A real receiver must authenticate the vehicle and assemble sparse fields before using this contract.
export function assembleTrips(vin, source, input, now = Date.now()) {
  if (!validVin(vin) || !sourceValues.has(source) || !Array.isArray(input) || input.length > 10000) throw new SafeError('车辆、来源或采样批次无效');
  const byTime = new Map();
  for (const raw of input) {
    const sample = normalizeSample(raw), at = Date.parse(sample.at);
    if (at > now || at <= now - RETENTION_MS - MAX_TRIP_MS) throw new SafeError('采样时间超出保留范围');
    const existing = byTime.get(sample.at);
    if (existing && JSON.stringify(existing) !== JSON.stringify(sample)) throw new SafeError('同一时刻存在冲突采样', 409);
    byTime.set(sample.at, sample);
  }
  const trips = [];
  let active = [];
  function finish(reason) {
    if (active.length > 1) {
      const start = active[0].at, end = active.at(-1).at;
      if (Date.parse(end) > now - RETENTION_MS) trips.push({ id: tripID(vin, source, start), vin, source,
        start, end, end_reason: reason, ...summarize(active), samples: active });
    }
    active = [];
  }
  for (const sample of [...byTime.values()].sort((a, b) => Date.parse(a.at) - Date.parse(b.at))) {
    if (active.length && (Date.parse(sample.at) - Date.parse(active.at(-1).at) > 300000 || Date.parse(sample.at) - Date.parse(active[0].at) > MAX_TRIP_MS)) finish('data_gap');
    if (!active.length && !['D', 'R'].includes(sample.gear)) continue;
    active.push(sample);
    if (sample.gear === 'P') finish('parked');
  }
  if (active.length && now - Date.parse(active.at(-1).at) >= 300000) finish('signal_timeout');
  return { trips, pending_samples: active.length };
}

export class HistoryStore {
  constructor(path, { allowSimulation = false, clock = Date.now } = {}) {
    if (path !== ':memory:') mkdirSync(dirname(path), { recursive: true, mode: 0o700 });
    this.db = new DatabaseSync(path);
    this.clock = clock; this.allowSimulation = allowSimulation;
    if (path !== ':memory:') chmodSync(path, 0o600);
    if (this.db.prepare('PRAGMA user_version').get().user_version > 1) {
      this.db.close(); throw new Error('History schema is newer than this server supports');
    }
    this.db.exec(`PRAGMA journal_mode=DELETE; PRAGMA secure_delete=ON; PRAGMA busy_timeout=5000;
      CREATE TABLE IF NOT EXISTS trips (id TEXT PRIMARY KEY, vin TEXT NOT NULL, ended INTEGER NOT NULL,
        source TEXT NOT NULL, payload TEXT NOT NULL, tag TEXT NOT NULL DEFAULT '', note TEXT NOT NULL DEFAULT '');
      CREATE INDEX IF NOT EXISTS trips_by_end ON trips(ended DESC, id);
      CREATE TABLE IF NOT EXISTS snapshots (vin TEXT PRIMARY KEY, fetched INTEGER NOT NULL, payload TEXT NOT NULL);
      CREATE TABLE IF NOT EXISTS deleted_trips (id TEXT PRIMARY KEY, ended INTEGER NOT NULL);
      PRAGMA user_version=1;`);
    this.prune();
  }
  close() { this.db.close(); }
  prune() {
    const cutoff = this.clock() - RETENTION_MS;
    const trips = this.db.prepare('DELETE FROM trips WHERE ended <= ?').run(cutoff).changes;
    const snapshots = this.db.prepare('DELETE FROM snapshots WHERE fetched <= ?').run(cutoff).changes;
    this.db.prepare('DELETE FROM deleted_trips WHERE ended <= ?').run(cutoff);
    return { trips, snapshots };
  }
  saveProbe(result) {
    if (!isRecord(result) || !validVin(result.vehicle?.vin)) throw new SafeError('车况存储格式无效');
    // An offline result must not renew a previously fetched live sample.
    if (!result.live_data) return;
    const fetched = timestamp(result.fetched_at);
    if (fetched > this.clock() || fetched <= this.clock() - RETENTION_MS || !isRecord(result.data)) throw new SafeError('车况时间或数据无效');
    // Only the whitelisted TeslaClient.probe projection is allowed here.
    const data = {};
    for (const key of ['charge_state', 'climate_state', 'vehicle_state', 'drive_state', 'location_data']) {
      if (isRecord(result.data[key])) data[key] = result.data[key];
    }
    const payload = JSON.stringify({ vehicle: result.vehicle, capability: result.capability ?? {}, data, fetched_at: iso(fetched), source: 'vehicle_data' });
    this.db.prepare(`INSERT INTO snapshots VALUES (?, ?, ?) ON CONFLICT(vin) DO UPDATE SET fetched=excluded.fetched,
      payload=excluded.payload WHERE excluded.fetched >= snapshots.fetched`).run(result.vehicle.vin, fetched, payload);
  }
  snapshot(vin) {
    if (!validVin(vin)) throw new SafeError('车辆标识无效');
    const row = this.db.prepare('SELECT payload, fetched FROM snapshots WHERE vin=? AND fetched>? AND fetched<=?').get(vin, this.clock() - RETENTION_MS, this.clock());
    return row ? { ...JSON.parse(row.payload), cached: true, stale: this.clock() - row.fetched >= 120000 } : null;
  }
  // Internal trusted ingestion only: never exposed as an unauthenticated HTTP upload.
  ingest(vin, source, samples) {
    if (source === 'simulation' && !this.allowSimulation) throw new SafeError('生产存储拒绝模拟数据', 403);
    const batch = assembleTrips(vin, source, samples, this.clock());
    this.db.exec('BEGIN IMMEDIATE');
    let inserted = 0;
    try {
      for (const trip of batch.trips) {
        if (this.db.prepare('SELECT id FROM deleted_trips WHERE id=?').get(trip.id)) continue;
        const payload = JSON.stringify(trip);
        const old = this.db.prepare('SELECT payload FROM trips WHERE id=?').get(trip.id);
        if (old && old.payload !== payload) throw new SafeError('已归档行程内容冲突，请核对采样批次', 409);
        if (!old) inserted += this.db.prepare('INSERT INTO trips (id, vin, ended, source, payload) VALUES (?, ?, ?, ?, ?)').run(trip.id, vin, Date.parse(trip.end), source, payload).changes;
      }
      this.db.exec('COMMIT');
    } catch (error) { this.db.exec('ROLLBACK'); throw error; }
    this.prune();
    return { inserted, pending_samples: batch.pending_samples };
  }
  list({ vin, limit = 30, before, from } = {}) {
    if (vin != null && !validVin(vin)) throw new SafeError('车辆标识无效');
    if (!Number.isInteger(limit) || limit < 1 || limit > 100) throw new SafeError('limit 必须在 1 到 100 之间');
    const lower = Math.max(this.clock() - RETENTION_MS, from === undefined ? -Infinity : timestamp(from));
    let cursor;
    if (before !== undefined) {
      try { cursor = JSON.parse(Buffer.from(before, 'base64url').toString()); } catch { throw new SafeError('分页游标无效'); }
      if (!isRecord(cursor) || !Number.isSafeInteger(cursor.ended) || typeof cursor.id !== 'string' || cursor.id.length > 64) throw new SafeError('分页游标无效');
    }
    const rows = this.db.prepare(`SELECT * FROM trips WHERE ended>? AND ended<=? AND (? IS NULL OR vin=?)
      AND (? IS NULL OR ended<? OR (ended=? AND id<?)) ORDER BY ended DESC, id DESC LIMIT ?`)
      .all(lower, this.clock(), vin ?? null, vin ?? null, cursor?.ended ?? null, cursor?.ended ?? null, cursor?.ended ?? null, cursor?.id ?? null, limit + 1);
    const more = rows.length > limit; rows.length = Math.min(rows.length, limit);
    const last = rows.at(-1);
    return { trips: rows.map(row => { const { samples, ...summary } = JSON.parse(row.payload); return { ...summary, sample_count: samples.length, tag: row.tag, note: row.note }; }),
      next_cursor: more ? Buffer.from(JSON.stringify({ ended: last.ended, id: last.id })).toString('base64url') : null, retention_hours: 168 };
  }
  detail(id) {
    const row = this.db.prepare('SELECT * FROM trips WHERE id=? AND ended>? AND ended<=?').get(id, this.clock() - RETENTION_MS, this.clock());
    if (!row) throw new SafeError('行程不存在或已过期', 404);
    return { ...JSON.parse(row.payload), tag: row.tag, note: row.note };
  }
  metadata(id, input) {
    if (!isRecord(input) || Object.keys(input).some(key => !['tag', 'note'].includes(key)) || typeof input.tag !== 'string' || typeof input.note !== 'string'
      || [...input.tag].length > 30 || [...input.note].length > 500) throw new SafeError('标签最多 30 字，备注最多 500 字');
    this.detail(id);
    this.db.prepare('UPDATE trips SET tag=?, note=? WHERE id=?').run(input.tag, input.note, id);
    return this.detail(id);
  }
  deleteTrip(id) {
    const trip = this.detail(id);
    this.db.exec('BEGIN IMMEDIATE');
    try {
      this.db.prepare('INSERT OR REPLACE INTO deleted_trips VALUES (?, ?)').run(id, Date.parse(trip.end));
      this.db.prepare('DELETE FROM trips WHERE id=?').run(id);
      this.db.exec('COMMIT');
    } catch (error) { this.db.exec('ROLLBACK'); throw error; }
  }
  stats() {
    const args = [this.clock() - RETENTION_MS, this.clock()];
    return { trips: this.db.prepare('SELECT COUNT(*) AS count FROM trips WHERE ended>? AND ended<=?').get(...args).count,
      snapshots: this.db.prepare('SELECT COUNT(*) AS count FROM snapshots WHERE fetched>? AND fetched<=?').get(...args).count,
      retention_hours: 168, cleanup_interval_seconds: 3600 };
  }
}

export function tripCSV(trip) {
  const cell = value => {
    let text = value == null ? '' : String(value);
    if (typeof value === 'string' && /^[\s]*[=+@\-]/u.test(text)) text = `'${text}`;
    return `"${text.replaceAll('"', '""')}"`;
  };
  const rows = [['source', 'trip_id', 'time_utc', 'latitude', 'longitude', 'speed_kph', 'power_kw', 'battery_percent', 'tag', 'note'],
    ...trip.samples.map(s => [trip.source, trip.id, s.at, s.latitude, s.longitude, s.speed_kph, s.power_kw, s.battery_percent, trip.tag, trip.note])];
  return '\uFEFF' + rows.map(row => row.map(cell).join(',')).join('\r\n') + '\r\n';
}
