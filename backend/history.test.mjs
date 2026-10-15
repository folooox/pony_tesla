import test from 'node:test';
import assert from 'node:assert/strict';
import { mkdtemp, rm, stat, writeFile } from 'node:fs/promises';
import { tmpdir } from 'node:os';
import { join } from 'node:path';
import { assembleTrips, HistoryStore, RETENTION_MS, tripCSV } from './history.mjs';
import { readiness, saveRegistration } from './readiness.mjs';
import { createApp } from './server.mjs';

const vin = 'LRW3E7FA0NC123456';
const now = Date.parse('2026-10-15T06:00:00Z');
const samples = (start = now - 3600000) => [0, 60, 120, 180].map((offset, i) => ({ at: new Date(start + offset * 1000).toISOString(),
  gear: i === 3 ? 'P' : 'D', latitude: 31.2 + i * .001, longitude: 121.4 + i * .001,
  speed_kph: i === 3 ? 0 : 30, power_kw: 12, battery_percent: 80 - i, odometer_km: 10000 + i * .5 }));
function store(clock = () => now, allowSimulation = true) { return new HistoryStore(':memory:', { clock, allowSimulation }); }
function using(action, clock) { const db = store(clock); try { return action(db); } finally { db.close(); } }

test('normalized batches sort and deduplicate samples without splitting red-light stops', () => {
  const points = samples(); points[1].speed_kph = 0;
  const result = assembleTrips(vin, 'simulation', [points[3], points[1], points[0], points[2], points[0]], now);
  assert.equal(result.trips.length, 1); assert.equal(result.pending_samples, 0);
  const trip = result.trips[0];
  assert.equal(trip.samples.length, 4); assert.equal(trip.distance_km, 1.5);
  assert.ok(Math.abs(trip.net_energy_kwh - .6) < .00001); assert.equal(trip.end_reason, 'parked');
});

test('missing power and odometer are not inferred from percentage changes', () => {
  const points = samples(); points[1].power_kw = null; points[0].odometer_km = null;
  const trip = assembleTrips(vin, 'simulation', points, now).trips[0];
  assert.equal(trip.net_energy_kwh, null); assert.equal(trip.distance_km, null);
  assert.equal(trip.energy_method, 'insufficient_data');
});

test('regeneration preserves signed power, while odometer rollback prevents a distance estimate', () => {
  const points = samples(); points.forEach(p => p.power_kw = -2); points[2].odometer_km = 1;
  const trip = assembleTrips(vin, 'simulation', points, now).trips[0];
  assert.ok(trip.net_energy_kwh < 0); assert.equal(trip.distance_km, null);
});

test('short missing intervals preserve a gap and suppress energy; long gaps split trips', () => {
  const points = samples(); points[2].at = new Date(now - 3600000 + 240000).toISOString(); points[3].at = new Date(now - 3600000 + 260000).toISOString();
  const trip = assembleTrips(vin, 'simulation', points, now).trips[0];
  assert.equal(trip.gap_count, 1); assert.equal(trip.net_energy_kwh, null);
  const batch = [...samples(), ...samples(now - 1800000)];
  batch[3].gear = 'D';
  const trips = assembleTrips(vin, 'simulation', batch, now).trips;
  assert.equal(trips.length, 2); assert.equal(trips[0].end_reason, 'data_gap');
});

test('unfinished batches stay pending; signal timeout finalizes incomplete recording explicitly', () => {
  const points = samples(now - 180000).slice(0, 3);
  assert.equal(assembleTrips(vin, 'simulation', points, now).pending_samples, 3);
  assert.equal(assembleTrips(vin, 'simulation', points, now + 300000).trips[0].end_reason, 'signal_timeout');
});

test('invalid samples, future timestamps and conflicting duplicates are rejected', () => {
  for (const change of [{ speed_kph: -1 }, { battery_percent: 101 }, { latitude: 91 }, { longitude: null },
    { power_kw: '12' }, { at: 'yesterday' }, { at: new Date(now + 1).toISOString() }, { gear: 'X' }]) {
    const points = samples(); points[0] = { ...points[0], ...change };
    assert.throws(() => assembleTrips(vin, 'simulation', points, now));
  }
  assert.throws(() => assembleTrips(vin, 'simulation', [...samples(), { ...samples()[0], speed_kph: 42 }], now), { status: 409 });
});

test('production history rejects simulation and duplicate replay is idempotent', () => {
  const prod = store(() => now, false);
  try { assert.throws(() => prod.ingest(vin, 'simulation', samples()), { status: 403 }); } finally { prod.close(); }
  using(db => {
    assert.equal(db.ingest(vin, 'simulation', samples()).inserted, 1);
    assert.equal(db.ingest(vin, 'simulation', samples()).inserted, 0);
    const changed = samples(); changed[1].power_kw = 0;
    assert.throws(() => db.ingest(vin, 'simulation', changed), { status: 409 });
    assert.equal(db.stats().trips, 1);
  });
});

test('a batch conflict rolls back earlier inserts in the same transaction', () => using(db => {
  db.ingest(vin, 'simulation', samples());
  const conflict = samples(); conflict[1].speed_kph = 99;
  assert.throws(() => db.ingest(vin, 'simulation', [...samples(now - 7200000), ...conflict]), { status: 409 });
  assert.equal(db.stats().trips, 1);
}));

test('retention uses end time, hides expired records immediately and deletes physical rows', () => {
  let clock = now;
  using(db => {
    const crossing = samples(now - RETENTION_MS - 120000);
    db.ingest(vin, 'simulation', crossing);
    const id = db.list().trips[0].id;
    assert.equal(db.detail(id).samples.length, 4);
    clock += 60000;
    assert.equal(db.list().trips.length, 0);
    assert.throws(() => db.detail(id), { status: 404 });
    assert.throws(() => db.metadata(id, { tag: '', note: '' }), { status: 404 });
    assert.equal(db.prune().trips, 1);
    assert.equal(db.db.prepare('SELECT COUNT(*) AS count FROM trips').get().count, 0);
  }, () => clock);
});

test('SQLite persists metadata across restart and cleanup runs on reopen', async () => {
  const dir = await mkdtemp(join(tmpdir(), 'pony-history-'));
  const path = join(dir, 'history.sqlite');
  let db;
  try {
    db = new HistoryStore(path, { allowSimulation: true, clock: () => now });
    db.ingest(vin, 'simulation', samples());
    const id = db.list().trips[0].id;
    db.metadata(id, { tag: '通勤', note: '真实持久化测试，模拟轨迹' }); db.close(); db = null;
    assert.equal((await stat(path)).mode & 0o777, 0o600);
    db = new HistoryStore(path, { allowSimulation: true, clock: () => now });
    assert.equal(db.detail(id).tag, '通勤'); db.close(); db = null;
    db = new HistoryStore(path, { clock: () => now + RETENTION_MS });
    assert.equal(db.stats().trips, 0);
  } finally { db?.close(); await rm(dir, { recursive: true, force: true }); }
});

test('cursor pagination is stable even when multiple vehicles finish at the same instant', () => using(db => {
  for (const v of [vin, 'LRW3E7FA0NC123457', 'LRW3E7FA0NC123458']) db.ingest(v, 'simulation', samples());
  const seen = []; let before;
  do { const page = db.list({ limit: 1, before }); seen.push(page.trips[0].id); before = page.next_cursor; } while (before);
  assert.equal(new Set(seen).size, 3);
  assert.equal(db.list({ vin }).trips.length, 1);
  for (const options of [{ limit: 101 }, { limit: 0 }, { vin: '../' }, { before: 'bad' }, { from: 'NaN' }]) assert.throws(() => db.list(options));
}));

test('metadata is validated and CSV preserves text while neutralizing spreadsheet formulas', () => using(db => {
  db.ingest(vin, 'simulation', samples()); const id = db.list().trips[0].id;
  assert.throws(() => db.metadata(id, { tag: '车'.repeat(31), note: '' }));
  const trip = db.metadata(id, { tag: '=SUM(A1)', note: '中文,"引号"\n换行' });
  const csv = tripCSV(trip);
  assert.ok(csv.startsWith('\uFEFF')); assert.ok(csv.includes("'=SUM(A1)")); assert.ok(csv.includes('""引号""'));
  assert.ok(csv.includes('simulation')); assert.ok(!csv.includes('undefined'));
  db.deleteTrip(id); assert.throws(() => db.detail(id), { status: 404 });
}));

function probe(at = now - 10000) { return { live_data: true, fetched_at: new Date(at).toISOString(), vehicle: { vin, state: 'online' },
  capability: {}, data: { charge_state: { battery_level: 71 }, access_token: 'excluded' } }; }

test('snapshots remain cached and offline or older probes never refresh live timestamps', () => {
  let clock = now;
  using(db => {
    db.saveProbe(probe()); db.saveProbe({ live_data: false, vehicle: { vin, state: 'asleep' } });
    db.saveProbe(probe(now - 100000));
    assert.equal(db.snapshot(vin).fetched_at, probe().fetched_at);
    assert.equal(db.snapshot(vin).cached, true); assert.equal(db.snapshot(vin).stale, false);
    assert.ok(!JSON.stringify(db.snapshot(vin)).includes('excluded'));
    clock += 120000; assert.equal(db.snapshot(vin).stale, true);
    clock += RETENTION_MS; assert.equal(db.snapshot(vin), null); assert.equal(db.prune().snapshots, 1);
  }, () => clock);
});

const settings = { missing: ['TESLA_CLIENT_ID', 'TESLA_CLIENT_SECRET'], adminPassword: 'a'.repeat(64), origin: 'https://test.example' };
async function serverTest(action, client = null) {
  const db = store(); db.ingest(vin, 'simulation', samples());
  const server = createApp(settings, client, null, db);
  await new Promise(resolve => server.listen(0, '127.0.0.1', resolve));
  const base = `http://127.0.0.1:${server.address().port}`;
  const headers = { authorization: `Basic ${Buffer.from(`owner:${settings.adminPassword}`).toString('base64')}`, origin: settings.origin, 'content-type': 'application/json' };
  try { await action({ db, base, headers }); }
  finally { server.closeAllConnections(); await new Promise(resolve => server.close(resolve)); db.close(); }
}

test('history HTTP API requires owner authentication and blocks cross-origin PATCH/DELETE', async () => serverTest(async ({ base, headers, db }) => {
  const id = db.list().trips[0].id;
  for (const path of ['/api/readiness', '/api/v1/history/status', '/api/v1/trips', `/api/v1/trips/${id}`, `/api/v1/trips/${id}/export.csv`]) {
    assert.equal((await fetch(base + path)).status, 401);
  }
  for (const method of ['PATCH', 'DELETE']) assert.equal((await fetch(`${base}/api/v1/trips/${id}`, { method, headers: { ...headers, origin: 'https://evil.invalid' }, body: '{}' })).status, 403);
}));

test('full HTTP history flow supports queries, detail, metadata, export and deletion', async () => serverTest(async ({ base, headers }) => {
  const request = (path, options = {}) => fetch(base + path, { headers, ...options });
  const listResponse = await request('/api/v1/trips?limit=1'); assert.equal(listResponse.status, 200);
  assert.equal(listResponse.headers.get('cache-control'), 'no-store');
  const list = await listResponse.json(); const id = list.trips[0].id;
  assert.equal(list.trips[0].samples, undefined);
  const detail = await (await request(`/api/v1/trips/${id}`)).json(); assert.equal(detail.trip.samples.length, 4);
  const updated = await request(`/api/v1/trips/${id}`, { method: 'PATCH', body: JSON.stringify({ tag: '通勤', note: '测试' }) });
  assert.equal((await updated.json()).trip.tag, '通勤');
  const exported = await request(`/api/v1/trips/${id}/export.csv`); assert.match(exported.headers.get('content-type'), /text\/csv/);
  assert.match(await exported.text(), /通勤/);
  assert.equal((await request(`/api/v1/trips/${id}`, { method: 'DELETE' })).status, 200);
  assert.equal((await request(`/api/v1/trips/${id}`)).status, 404);
  assert.equal((await (await request('/api/v1/history/status')).json()).trips, 0);
}));

test('history API rejects malformed queries and oversized metadata without corrupting records', async () => serverTest(async ({ base, headers, db }) => {
  for (const query of ['limit=0', 'limit=2&limit=3', 'from=invalid', 'before=bad', 'other=1']) assert.equal((await fetch(`${base}/api/v1/trips?${query}`, { headers })).status, 400);
  const id = db.list().trips[0].id;
  for (const body of ['null', '{}', '[]', '{']) assert.equal((await fetch(`${base}/api/v1/trips/${id}`, { method: 'PATCH', headers, body })).status, 400);
  assert.equal((await fetch(`${base}/api/v1/trips/${id}`, { method: 'PATCH', headers, body: JSON.stringify({ tag: '', note: '车'.repeat(2000) }) })).status, 413);
  assert.equal(db.detail(id).note, '');
  assert.equal((await fetch(`${base}/api/v1/ingest`, { method: 'POST', headers, body: '{}' })).status, 404);
}));

test('successful vehicle read persists a separately retrievable cache', async () => serverTest(async ({ base, headers }) => {
  assert.equal((await fetch(`${base}/api/v1/vehicles/${vin}/snapshot`, { headers })).status, 404);
  const result = await fetch(`${base}/api/probe`, { method: 'POST', headers, body: JSON.stringify({ vin }) });
  assert.equal(result.status, 200);
  const saved = await (await fetch(`${base}/api/v1/vehicles/${vin}/snapshot`, { headers })).json();
  assert.equal(saved.snapshot.data.charge_state.battery_level, 71);
  assert.equal(saved.snapshot.cached, true);
}, { probe: async () => probe() }));

test('readiness reports configuration, authorization and collection as distinct stages without secrets', async () => serverTest(async ({ base, headers }) => {
  const result = await (await fetch(`${base}/api/readiness`, { headers })).json();
  assert.equal(result.stages.configuration.status, 'missing');
  assert.equal(result.stages.authorization.status, 'not_authorized');
  assert.equal(result.stages.history.status, 'available');
  assert.equal(result.stages.telemetry.status, 'not_connected');
  assert.equal(result.stages.native_session.status, 'not_implemented');
  assert.ok(!JSON.stringify(result).includes(settings.adminPassword));
}));

test('registration receipt binds to application, domain and public key, and never claims fresh verification', async () => {
  const dir = await mkdtemp(join(tmpdir(), 'pony-registration-'));
  const config = { ...settings, dir, clientId: 'fixture-id', missing: [] };
  try {
    await writeFile(join(dir, 'public-key.pem'), 'fixture-public-key');
    await saveRegistration(config, 'fixture-public-key');
    const saved = await readiness(config, { read: async () => ({ access_token: 'secret' }) }, null);
    assert.equal(saved.stages.registration.status, 'recorded'); assert.equal(saved.stages.authorization.status, 'token_saved');
    assert.ok(!JSON.stringify(saved).includes('secret'));
    assert.equal((await readiness({ ...config, clientId: 'other-id' }, null, null)).stages.registration.status, 'configuration_changed');
    assert.equal((await readiness({ ...config, origin: 'https://other.invalid' }, null, null)).stages.registration.status, 'configuration_changed');
  } finally { await rm(dir, { recursive: true, force: true }); }
});

test('replayed batches cannot resurrect explicitly deleted trips; deletion markers expire', () => {
  let clock = now;
  using(db => {
    db.ingest(vin, 'simulation', samples()); const id = db.list().trips[0].id;
    db.deleteTrip(id);
    assert.equal(db.ingest(vin, 'simulation', samples()).inserted, 0);
    assert.equal(db.stats().trips, 0);
    clock += RETENTION_MS; db.prune();
    assert.equal(db.db.prepare('SELECT COUNT(*) AS count FROM deleted_trips').get().count, 0);
  }, () => clock);
});
