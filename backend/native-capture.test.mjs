import test from 'node:test';
import assert from 'node:assert/strict';
import { mkdtempSync, rmSync, statSync, symlinkSync, readFileSync, realpathSync } from 'node:fs';
import { DatabaseSync } from 'node:sqlite';
import { tmpdir } from 'node:os';
import { join } from 'node:path';
import { NativeCaptureStore, CAPTURE_LIMITS, RETENTION_MS } from './native-capture.mjs';

const NOW = Date.parse('2026-10-19T12:00:00Z');
const VIN = 'LRW3E7FA0NC123456', OTHER = 'LRW3E7FA0NC123457';
const alice = Object.freeze({}), bob = Object.freeze({}), operator = Object.freeze({}), receiver = Object.freeze({}), receiverOther = Object.freeze({});
function options(clock = () => NOW, allowSimulation = true) {
  return { clock, allowSimulation, authenticateAccount: context => context === alice ? 'account-a' : context === bob ? 'account-b' : null,
    authorizeOperator: context => context === operator,
    authenticateReceiver: context => context === receiver ? { vin: VIN, stream: 'fixture-stream' } : context === receiverOther ? { vin: OTHER, stream: 'fixture-stream' } : null };
}
const at = seconds => new Date(NOW - 3600000 + seconds * 1000).toISOString();
const trip = (id, seconds, gear = 'D', extra = {}) => ({ id, kind: 'trip', at: at(seconds), gear, speed_kph: gear === 'P' ? 0 : 20,
  power_kw: 12, odometer_km: 1000 + seconds / 100, battery_percent: 80, ...extra });
const charge = (id, seconds, state = 'Charging', energy = null) => ({ id, kind: 'charge', at: at(seconds), charge_state: state,
  charger_type: 'ac', battery_percent: 50, energy_added_kwh: energy });
const drive = () => [trip('p', 0, 'P'), trip('d1', 10), trip('d2', 60), trip('end', 90, 'P')];
const charging = () => [charge('idle', 0, 'Disconnected'), charge('c1', 10, 'Charging', 0), charge('c2', 60, 'Charging', 1), charge('done', 90, 'Complete', 2)];
function bind(db, extra = {}) { return db.register(operator, { account: 'account-a', vin: VIN, stream: 'fixture-stream', source: 'simulation', expires_at: new Date(NOW + 60000).toISOString(), ...extra }).binding_id; }
function using(action) { const db = new NativeCaptureStore(':memory:', options()); try { return action(db, bind(db)); } finally { db.close(); } }
const list = (db, context = alice, vin = VIN, extra = {}) => db.list(context, { vin, ...extra });

test('default trust seams deny everything and real stores refuse simulation', () => {
  const db = new NativeCaptureStore(':memory:');
  try { assert.throws(() => bind(db), { status: 403 }); assert.throws(() => list(db), { status: 401 }); assert.throws(() => db.ingest(receiver, 'x', drive()), { status: 401 }); } finally { db.close(); }
  const real = new NativeCaptureStore(':memory:', options(() => NOW, false));
  try { assert.throws(() => bind(real), { status: 403 }); const id = bind(real, { source: 'telemetry' }); real.ingest(receiver, id, drive()); assert.equal(list(real).records[0].source, 'telemetry'); } finally { real.close(); }
});

test('durable pending trip is not finalized by batch end or inactivity; confirmed P closes it', () => using((db, id) => {
  db.ingest(receiver, id, drive().slice(0, 3));
  let record = list(db).records[0]; assert.equal(record.end, null); assert.equal(record.end_reason, 'in_progress'); assert.equal(record.complete, false);
  const original = record.id;
  db.ingest(receiver, id, [drive()[3]]);
  record = db.detail(alice, VIN, original);
  assert.equal(record.end_reason, 'parked'); assert.equal(record.complete, true); assert.equal(record.start, at(10)); assert.equal(record.end, at(90));
  assert.equal(record.samples.length, 3); assert.ok(Math.abs(record.distance_km - .8) < 1e-9); assert.equal(record.cost, null);
}));

test('missed trip and charge starts stay null; single observed sessions remain incomplete', () => using((db, id) => {
  db.ingest(receiver, id, [trip('t', 10), trip('tp', 60, 'P'), charge('c', 100), charge('ce', 110, 'Stopped')]);
  const rows = list(db).records; assert.equal(rows.length, 2);
  for (const row of rows) { assert.equal(row.start, null); assert.equal(row.complete, false); assert.equal(row.cost, null); }
  const c = rows.find(r => r.kind === 'charge'); assert.equal(c.energy_added_kwh, null);
}));

test('sorted out-of-order replay is idempotent and conflicts roll back entire journal batch', () => using((db, id) => {
  const points = drive(); db.ingest(receiver, id, [points[3], points[0], points[2], points[1]]);
  const first = list(db).records[0]; assert.equal(first.complete, true);
  const retry = db.ingest(receiver, id, points); assert.equal(retry.duplicates, 4); assert.equal(list(db).records[0].revision, first.revision);
  const count = db.db.prepare('SELECT count(*) AS n FROM events').get().n;
  assert.throws(() => db.ingest(receiver, id, [trip('new', 100), { ...points[1], speed_kph: 99 }]), { status: 409 });
  assert.equal(db.db.prepare('SELECT count(*) AS n FROM events').get().n, count);
  assert.throws(() => db.ingest(receiver, id, [{ ...points[1], id: 'different' }]), { status: 409 });
}));

test('late sample updates stable record revision without losing annotations', () => using((db, id) => {
  db.ingest(receiver, id, [trip('late-start', 60), trip('late-end', 90, 'P')]);
  const first = list(db).records[0];
  db.annotate(alice, VIN, first.id, { tag: 'commute', note: 'preserved' });
  db.ingest(receiver, id, [trip('baseline', 0, 'P'), trip('earlier', 10)]);
  const updated = db.detail(alice, VIN, first.id);
  assert.equal(updated.start, at(10)); assert.equal(updated.complete, true); assert.equal(updated.tag, 'commute'); assert.ok(updated.revision > first.revision);
}));

test('gaps split interrupted records, zero speed does not park, no inferred routes or missing measurements', () => using((db, id) => {
  db.ingest(receiver, id, [trip('p', 0, 'P'), trip('d', 10, 'D', { speed_kph: 0, power_kw: null, odometer_km: null }), trip('later', 300), trip('end', 330, 'P')]);
  const records = list(db).records; assert.equal(records.length, 2);
  const interrupted = records.find(r => r.end_reason === 'data_gap'); assert.equal(interrupted.end, null); assert.equal(interrupted.complete, false);
  assert.equal(interrupted.distance_km, null); assert.equal(interrupted.net_energy_kwh, null);
  const detail = db.detail(alice, VIN, interrupted.id); assert.equal(detail.samples[0].latitude, null); assert.equal(detail.samples[0].longitude, null);
}));

test('charge observed counter delta uses a fixed basis, never cost or battery-percentage-derived energy', () => using((db, id) => {
  db.ingest(receiver, id, charging());
  const c = list(db).records[0]; assert.equal(c.complete, true); assert.equal(c.energy_added_kwh, 2); assert.equal(c.energy_basis, 'battery_session_counter');
  assert.equal(c.charger_type, 'ac'); assert.equal(c.cost, null); assert.equal(c.cost_currency, null);
}));

test('counter reset explicitly splits intervals, unknown counters remain unknown, charge gaps remain incomplete', () => using((db, id) => {
  db.ingest(receiver, id, [charge('idle', 0, 'Stopped'), charge('a', 10, 'Charging', 5), charge('b', 60, 'Charging', 6), charge('reset', 90, 'Charging', 0), charge('unknown', 100), charge('end', 110, 'Complete', 2), charge('again', 400, 'Charging', 3)]);
  const rows = list(db).records; assert.equal(rows.length, 3);
  const reset = rows.find(r => r.end_reason === 'counter_reset'); assert.equal(reset.energy_added_kwh, 1); assert.equal(reset.complete, false);
  const ended = rows.find(r => r.end_reason === 'Complete'); assert.equal(ended.energy_added_kwh, null); assert.equal(ended.start, null);
  const pending = rows.find(r => r.end_reason === 'in_progress'); assert.equal(pending.start, null); assert.equal(pending.end, null);
}));

test('account and authenticated VIN isolation, no self-asserted receiver/account route', () => using((db, id) => {
  db.ingest(receiver, id, drive()); const record = list(db).records[0];
  assert.equal(list(db, bob).records.length, 0); assert.equal(list(db, alice, OTHER).records.length, 0);
  assert.throws(() => db.detail(bob, VIN, record.id), { status: 404 }); assert.throws(() => db.detail(alice, OTHER, record.id), { status: 404 });
  assert.throws(() => db.ingest({ vin: VIN, stream: 'fixture-stream', verified: true }, id, drive()), { status: 401 });
  assert.throws(() => db.ingest(receiverOther, id, drive()), { status: 403 }); assert.throws(() => list(db, { account: 'account-a' }), { status: 401 });
  const second = bind(db, { account: 'account-b', vin: OTHER }); db.ingest(receiverOther, second, drive());
  assert.equal(list(db, bob, OTHER).records.length, 1); assert.equal(list(db, alice, OTHER).records.length, 0);
}));

test('opt-out revokes binding immediately; expiration rejects stream until trusted operator re-enables', () => {
  let clock = NOW; const db = new NativeCaptureStore(':memory:', options(() => clock));
  try {
    const id = bind(db); db.ingest(receiver, id, drive());
    assert.throws(() => db.revoke(bob, id), { status: 404 }); db.revoke(alice, id);
    assert.throws(() => db.ingest(receiver, id, [trip('new', 100)]), { status: 403 }); assert.equal(list(db).records.length, 1);
    assert.throws(() => bind(db, { expires_at: new Date(clock + CAPTURE_LIMITS.bindingTTL + 1).toISOString() }));
    clock += 60001;
    const renewed = bind(db, { expires_at: new Date(clock + 60000).toISOString() }); assert.equal(renewed, id);
    assert.equal(db.ingest(receiver, id, [trip('old-backfill', 110)]).suppressed, 1);
    clock += 60001; assert.throws(() => db.ingest(receiver, id, [trip('newer', 120)]), { status: 403 });
  } finally { db.close(); }
});

test('restart retains pending charge/trip and committed-but-unprocessed journal, private filesystem modes', () => {
  const dir = mkdtempSync(join(realpathSync(tmpdir()), 'pony-capture-')); const path = join(dir, 'capture.sqlite'); let db;
  try {
    db = new NativeCaptureStore(path, options()); const id = bind(db);
    db.ingest(receiver, id, [drive()[0], drive()[1], charging()[0], charging()[1]]);
    const before = list(db).records.map(r => r.id).sort();
    const originalReplay = db.replay; db.replay = () => { throw new Error('synthetic process interruption after commit'); };
    assert.throws(() => db.ingest(receiver, id, [drive()[2], charging()[2]]), /synthetic/); db.replay = originalReplay;
    db.close(); db = new NativeCaptureStore(path, options());
    assert.deepEqual(list(db).records.map(r => r.id).sort(), before);
    assert.equal(list(db).records.every(r => r.end === null), true);
    assert.equal(db.db.prepare('SELECT count(*) AS n FROM events').get().n, 6);
    db.ingest(receiver, id, [drive()[3], charging()[3]]); assert.equal(list(db).records.every(r => r.complete), true);
    assert.equal(statSync(path).mode & 0o777, 0o600); assert.equal(statSync(dir).mode & 0o777, 0o700);
  } finally { db?.close(); rmSync(dir, { recursive: true, force: true }); }
});

test('seven-day pruning removes raw pending and completed data on reads and restart', () => {
  let clock = NOW; const db = new NativeCaptureStore(':memory:', options(() => clock));
  try {
    const id = bind(db); db.ingest(receiver, id, [...drive(), charge('pending', 120)]);
    assert.equal(db.db.prepare('SELECT count(*) AS n FROM events').get().n, 5);
    clock += RETENTION_MS;
    assert.equal(list(db).records.length, 0); assert.equal(db.db.prepare('SELECT count(*) AS n FROM events').get().n, 0);
    assert.equal(db.db.prepare('SELECT count(*) AS n FROM records').get().n, 0);
  } finally { db.close(); }
});

test('annotation validation, source-aware formula-safe CSV, detail and scoped cursor metadata', () => using((db, id) => {
  db.ingest(receiver, id, [...drive(), ...charging()]);
  const first = list(db, alice, VIN, { limit: 1 }); assert.ok(first.next_cursor); assert.equal(first.retention_hours, 168);
  const second = list(db, alice, VIN, { limit: 1, before: first.next_cursor }); assert.equal(second.next_cursor, null); assert.notEqual(second.records[0].id, first.records[0].id);
  assert.throws(() => list(db, bob, VIN, { before: first.next_cursor }));
  const record = first.records[0]; assert.throws(() => db.annotate(alice, VIN, record.id, { tag: 'x'.repeat(31), note: '' }));
  assert.throws(() => db.annotate(alice, VIN, record.id, { tag: '', note: '\u0000' }));
  db.annotate(alice, VIN, record.id, { tag: '=SUM(A1)', note: '中文,"quoted"\nline' });
  const csv = db.exportCSV(alice, VIN, record.id);
  assert.ok(csv.startsWith('\uFEFF')); assert.ok(csv.includes('simulation')); assert.ok(csv.includes("'=SUM(A1)")); assert.ok(csv.includes('""quoted""')); assert.ok(!csv.includes('undefined'));
}));

test('record deletion erases raw samples and suppresses replay/late samples across rebinding; delete-all keeps high watermark', () => using((db, id) => {
  db.ingest(receiver, id, drive()); const record = list(db).records[0]; db.deleteRecord(alice, VIN, record.id);
  assert.throws(() => db.detail(alice, VIN, record.id), { status: 404 });
  assert.equal(db.db.prepare('SELECT count(*) AS n FROM events').get().n, 1); // pre-trip P baseline is not part of the deleted trip
  assert.equal(db.ingest(receiver, id, drive()).suppressed, 3); assert.equal(list(db).records.length, 0);
  const another = bind(db, { stream: 'other-stream' });
  const secondContext = {}; db.authenticateReceiver = c => c === secondContext ? { vin: VIN, stream: 'other-stream' } : options().authenticateReceiver(c);
  assert.equal(db.ingest(secondContext, another, drive()).suppressed, 3);
  db.ingest(receiver, id, [trip('new-baseline', 500, 'P'), trip('new-trip', 510), trip('new-end', 550, 'P')]);
  assert.equal(list(db).records.length, 1); db.deleteAll(alice, VIN);
  assert.equal(list(db).records.length, 0); assert.equal(db.db.prepare('SELECT count(*) AS n FROM events').get().n, 0);
  assert.equal(db.ingest(receiver, id, [trip('replay-new-trip', 510)]).suppressed, 1);
}));

test('input bounds reject malformed units/times/fields and excessive batches without inserting data', () => using((db, id) => {
  const invalid = [trip('bad', 0, 'X'), trip('bad', 0, 'D', { speed_kph: NaN }), trip('bad', 0, 'D', { power_kw: Infinity }),
    trip('bad', 0, 'D', { latitude: 30 }), trip('bad', 0, 'D', { battery_percent: 101 }), trip('bad', 0, 'D', { speed_kph: '20' }),
    trip('bad', 0, 'D', { at: '2026-02-30T12:00:00Z' }), trip('bad', 0, 'D', { at: new Date(NOW + 1).toISOString() }),
    trip('bad', 0, 'D', { at: new Date(NOW - RETENTION_MS).toISOString() }), trip('bad', 0, 'D', { account: 'account-b' }),
    charge('bad', 0, 'charging'), { ...charge('bad', 0), charger_type: 'supercharger' }, { ...charge('bad', 0), energy_added_kwh: -1 }];
  for (const point of invalid) assert.throws(() => db.ingest(receiver, id, [point]));
  assert.throws(() => db.ingest(receiver, id, [])); assert.throws(() => db.ingest(receiver, id, Array(CAPTURE_LIMITS.batch + 1).fill(trip('x', 0))));
  assert.throws(() => db.ingest(receiver, id, [{ ...trip('big', 0), extra: 'x'.repeat(CAPTURE_LIMITS.bytes) }]), { status: 413 });
  assert.equal(db.db.prepare('SELECT count(*) AS n FROM events').get().n, 0);
  assert.throws(() => list(db, alice, VIN, { limit: 101 })); assert.throws(() => list(db, alice, VIN, { before: 'bad' }));
}));

// Deliberately separate adjacent sessions by less than MAX_GAP_MS: deletion must not erase the neighbor.
test('deleting one adjacent trip and charge preserves the other sessions before and after restart', () => {
  const dir = mkdtempSync(join(realpathSync(tmpdir()), 'pony-capture-delete-')); const path = join(dir, 'capture.sqlite'); let db;
  try {
    db = new NativeCaptureStore(path, options()); const binding = bind(db);
    db.ingest(receiver, binding, [trip('base', 0, 'P'), trip('first', 10), trip('first-end', 30, 'P'), trip('second', 40), trip('second-end', 60, 'P'),
      charge('charge-base', 0, 'Stopped'), charge('charge-first', 10, 'Charging', 0), charge('charge-first-end', 30, 'Complete', 1),
      charge('charge-second', 40, 'Charging', 0), charge('charge-second-end', 60, 'Complete', 2)]);
    const trips = list(db, alice, VIN, { kind: 'trip' }).records;
    const charges = list(db, alice, VIN, { kind: 'charge' }).records;
    const firstTrip = trips.find(r => r.first_observed_at === at(10)); const secondTrip = trips.find(r => r.first_observed_at === at(40));
    const firstCharge = charges.find(r => r.first_observed_at === at(10)); const secondCharge = charges.find(r => r.first_observed_at === at(40));
    db.annotate(alice, VIN, secondTrip.id, { tag: 'survivor', note: 'unchanged' });
    db.deleteRecord(alice, VIN, firstTrip.id); db.deleteRecord(alice, VIN, firstCharge.id);
    assert.equal(list(db).records.length, 2);
    assert.deepEqual(db.detail(alice, VIN, secondTrip.id).samples.map(s => s.id), ['second', 'second-end']);
    assert.deepEqual(db.detail(alice, VIN, secondCharge.id).samples.map(s => s.id), ['charge-second', 'charge-second-end']);
    assert.equal(db.db.prepare('SELECT count(*) AS n FROM events WHERE id IN (?,?,?,?)').get('first', 'first-end', 'charge-first', 'charge-first-end').n, 0);
    assert.equal(db.ingest(receiver, binding, [trip('late-within-deleted', 20)]).suppressed, 1);
    db.close(); db = new NativeCaptureStore(path, options());
    assert.equal(list(db).records.length, 2); assert.equal(db.detail(alice, VIN, secondTrip.id).tag, 'survivor');
    assert.equal(db.detail(alice, VIN, secondCharge.id).energy_added_kwh, 2);
    assert.throws(() => db.detail(alice, VIN, firstTrip.id), { status: 404 }); assert.throws(() => db.detail(alice, VIN, firstCharge.id), { status: 404 });
  } finally { db?.close(); rmSync(dir, { recursive: true, force: true }); }
});

test('renewing revoked binding at capacity succeeds; new binding and event overflow reject atomically', () => using((db, id) => {
  db.transaction(() => {
    const put = db.db.prepare('INSERT INTO bindings(id,account,vin,source,stream,basis,expires,revoked) VALUES(?,?,?,?,?,?,?,1)');
    for (let i = 1; i < CAPTURE_LIMITS.bindings; i++) put.run(`capacity-${i}`, 'account-a', VIN, 'simulation', `stream-${i}`, 'battery_session_counter', NOW + 60000);
  });
  db.revoke(alice, id); assert.equal(bind(db), id);
  assert.throws(() => bind(db, { stream: 'overflow-stream' }), { status: 429 });
  // Seed bounded historical rows directly to exercise the capacity guard without 40 full replays.
  db.transaction(() => {
    const put = db.db.prepare('INSERT INTO events VALUES(?,?,?,?,?)');
    for (let i = 0; i < CAPTURE_LIMITS.eventsPerBinding; i++) {
      const point = trip(`capacity-event-${i}`, -1000 - i, 'P');
      put.run(id, point.id, Date.parse(point.at), point.kind, JSON.stringify(point));
    }
  });
  // Revocation floor suppresses old backfill; use a legitimately newer sample to reach the count guard.
  const futureObserved = { ...trip('overflow-event', 0), at: new Date(NOW + 1).toISOString() };
  const oldClock = db.clock; db.clock = () => NOW + 2;
  try { assert.throws(() => db.ingest(receiver, id, [futureObserved]), { status: 429 }); }
  finally { db.clock = oldClock; }
  assert.equal(db.db.prepare('SELECT count(*) AS n FROM events').get().n, CAPTURE_LIMITS.eventsPerBinding);
  assert.equal(db.db.prepare('SELECT id FROM events WHERE id=?').get('overflow-event'), undefined);
}));

test('foreign/newer databases and symlink paths are rejected without modifying existing files', () => {
  const dir = mkdtempSync(join(realpathSync(tmpdir()), 'pony-capture-path-'));
  try {
    const foreign = join(dir, 'legacy.sqlite'); const legacy = new DatabaseSync(foreign);
    legacy.exec('CREATE TABLE legacy(secret TEXT); INSERT INTO legacy VALUES(\'untouched\');'); legacy.close();
    const before = readFileSync(foreign);
    assert.throws(() => new NativeCaptureStore(foreign, options()), /Not a native capture database/);
    assert.deepEqual(readFileSync(foreign), before);
    const newerPath = join(dir, 'newer.sqlite'); const newer = new DatabaseSync(newerPath);
    newer.exec('PRAGMA application_id=1347309379; PRAGMA user_version=3;'); newer.close();
    const newerBefore = readFileSync(newerPath);
    assert.throws(() => new NativeCaptureStore(newerPath, options()), /Unsupported capture schema/);
    assert.deepEqual(readFileSync(newerPath), newerBefore);
    const link = join(dir, 'linked.sqlite'); symlinkSync(foreign, link);
    assert.throws(() => new NativeCaptureStore(link, options()), /Unsafe capture database path/);
    const parent = join(dir, 'linked-directory'); symlinkSync(dir, parent);
    assert.throws(() => new NativeCaptureStore(join(parent, 'new.sqlite'), options()), /Unsafe capture database path/);
    const dangling = join(dir, 'dangling.sqlite'); symlinkSync(join(dir, 'missing.sqlite'), dangling);
    assert.throws(() => new NativeCaptureStore(dangling, options()), /Unsafe capture database path/);
  } finally { rmSync(dir, { recursive: true, force: true }); }
});

test('account validator receives fresh VIN on every read and can revoke membership immediately', () => using((db, id) => {
  db.ingest(receiver, id, drive()); const record = list(db).records[0]; let allowed = true; const calls = [];
  db.authenticateAccount = (context, vin) => { calls.push(vin); return context === alice && allowed && vin === VIN ? 'account-a' : null; };
  assert.equal(list(db).records.length, 1); allowed = false;
  assert.throws(() => db.detail(alice, VIN, record.id), { status: 401 }); assert.throws(() => db.exportCSV(alice, VIN, record.id), { status: 401 });
  assert.deepEqual(calls, [VIN, VIN, VIN]);
}));

test('CSV repeats persisted incomplete reasons and observation metadata without inventing current activity', () => using((db, id) => {
  db.ingest(receiver, id, [trip('gap-first', 10), trip('gap-later', 300),
    charge('reset-first', 10, 'Charging', 5), charge('reset-before', 20, 'Charging', 6), charge('reset-after', 30, 'Charging', 0)]);
  const records = list(db).records;
  assert.equal(records.length, 4);
  assert.ok(records.some(r => r.end_reason === 'data_gap'));
  assert.ok(records.some(r => r.end_reason === 'counter_reset'));
  assert.ok(records.some(r => r.end_reason === 'in_progress'));
  for (const record of records) {
    const detail = db.annotate(alice, VIN, record.id, { tag: '=SUM(A1)', note: 'synthetic' });
    const csv = db.exportCSV(alice, VIN, record.id);
    assert.ok(csv.includes("'=SUM(A1)"));
    // These fixtures contain no commas/newlines/quotes in cells; decode their quoted fields directly.
    const [header, ...rows] = csv.slice(1).trimEnd().split('\r\n').map(line => line.split(',').map(cell => JSON.parse(cell)));
    assert.equal(rows.length, detail.samples.length);
    for (const row of rows) {
      const values = Object.fromEntries(header.map((key, index) => [key, row[index]]));
      assert.equal(values.source, 'simulation');
      assert.equal(values.start, ''); assert.equal(values.end, '');
      assert.equal(values.start_observed, 'false'); assert.equal(values.complete, 'false');
      assert.equal(values.end_reason, detail.end_reason);
      assert.equal(values.first_observed_at, detail.first_observed_at);
      assert.equal(values.last_observed_at, detail.last_observed_at);
      assert.equal(values.energy_method, detail.energy_method);
      assert.equal(values.energy_basis, detail.energy_basis ?? '');
      assert.equal(values.record_revision, String(detail.revision));
    }
    assert.ok(!csv.includes('undefined')); assert.ok(!csv.includes('currently collecting'));
  }
}));
