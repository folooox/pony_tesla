import test from 'node:test';
import assert from 'node:assert/strict';
import { mkdtempSync, rmSync, readFileSync } from 'node:fs';
import { tmpdir } from 'node:os';
import { join } from 'node:path';
import { spawnSync } from 'node:child_process';
import { DatabaseSync } from 'node:sqlite';
import { NativeCaptureStore, CAPTURE_LIMITS, RETENTION_MS } from './native-capture.mjs';

const NOW = Date.parse('2026-10-20T05:00:00Z');
const VIN = 'LRW3E7FA0NC123456';
const at = seconds => new Date(NOW - 3600000 + seconds * 1000).toISOString();
const valid = value => ({ valid: true, value });
const p = (id, seconds, fields) => ({ id, kind: 'trip', at: at(seconds), fields });
const gear = (id, seconds, value) => p(id, seconds, { gear: valid(value) });
function options(clock = () => NOW) {
  return { clock, authenticateAccount: c => c === 'owner' ? 'account-a' : null,
    authorizeOperator: c => c === 'operator',
    authenticateReceiver: c => c === 'receiver' ? { vin: VIN, stream: 'sparse-fixture' } : null };
}
function bind(db) {
  return db.register('operator', { account: 'account-a', vin: VIN, stream: 'sparse-fixture',
    source: 'telemetry', expires_at: new Date(db.clock() + 60000).toISOString() }).binding_id;
}
const rows = db => db.list('owner', { vin: VIN }).records;
const ingest = (db, id, points) => db.ingestPatches('receiver', id, points);
const detail = db => rows(db).map(r => db.detail('owner', VIN, r.id));
function using(action) { const db = new NativeCaptureStore(':memory:', options()); try { action(db, bind(db)); } finally { db.close(); } }
const drive = () => [gear('baseline', 0, 'P'), gear('drive', 10, 'D'), gear('end', 90, 'P')];

test('sparse exact-time union preserves absence, stable anchor, ID and annotations; duplicate has no revision churn', () => using((db, id) => {
  ingest(db, id, drive());
  const initial = rows(db)[0];
  db.annotate('owner', VIN, initial.id, { tag: 'commute', note: 'keep' });
  const battery = p('battery-other-id', 10, { battery_percent: valid(81) });
  ingest(db, id, [battery]);
  const enriched = db.detail('owner', VIN, initial.id);
  assert.equal(enriched.tag, 'commute'); assert.equal(enriched.note, 'keep');
  assert.equal(enriched.samples.length, 2); assert.equal(enriched.samples[0].battery_percent, 81);
  assert.equal(enriched.samples[1].battery_percent, null); // never fill forward
  assert.equal(Object.hasOwn(enriched.samples[1].fields, 'battery_percent'), false);
  assert.equal(enriched.samples[0].id, db.detail('owner', VIN, initial.id).samples[0].id);
  assert.equal(ingest(db, id, [battery]).duplicates, 1);
  assert.equal(db.detail('owner', VIN, initial.id).revision, enriched.revision);
  // Different transport ID with identical same-time presence also cannot churn DTOs.
  ingest(db, id, [{ ...battery, id: 'duplicate-delivery' }]);
  assert.equal(db.detail('owner', VIN, initial.id).revision, enriched.revision);
  assert.equal(enriched.complete, true); assert.equal(enriched.distance_km, null); assert.equal(enriched.net_energy_kwh, null);
  assert.equal(enriched.cost, null); assert.equal(enriched.source, 'telemetry');
  assert.equal(db.list('owner', { vin: VIN, kind: 'charge' }).records.length, 0);
}));

test('same identity can enrich presence, conflicts and time moves roll back the entire batch', () => using((db, id) => {
  ingest(db, id, drive());
  ingest(db, id, [p('drive', 10, { battery_percent: valid(80) })]);
  for (const conflicting of [gear('new-id', 10, 'R'), p('drive', 10, { gear: { valid: false } }),
    p('different-battery', 10, { battery_percent: { valid: false } }), gear('drive', 11, 'D')]) {
    const before = db.db.prepare('SELECT * FROM patches ORDER BY id').all();
    assert.throws(() => ingest(db, id, [gear('must-rollback', 120, 'D'), conflicting]), { status: 409 });
    assert.deepEqual(db.db.prepare('SELECT * FROM patches ORDER BY id').all(), before);
  }
  // One millisecond is not a union bucket.
  ingest(db, id, [{ ...p('one-ms', 10, { battery_percent: valid(79) }), at: at(10).replace('.000Z', '.001Z') }]);
  assert.equal(detail(db)[0].samples.length, 3);
}));

test('absent gear preserves open context and P baseline; invalid gear explicitly breaks confirmation', () => using((db, id) => {
  ingest(db, id, [gear('p', 0, 'P'), p('b0', 5, { battery_percent: valid(80) }), gear('d', 10, 'D'),
    p('b1', 20, { battery_percent: { valid: false } })]);
  let record = detail(db)[0]; assert.equal(record.start, at(10)); assert.equal(record.end, null);
  assert.equal(record.samples.at(-1).fields.battery_percent.valid, false);
  assert.equal(record.samples.at(-1).gear, 'unknown');
  ingest(db, id, [p('invalid', 30, { gear: { valid: false } }), gear('d2', 40, 'D'), gear('p2', 60, 'P')]);
  const all = detail(db); assert.equal(all.length, 2); assert.ok(all.every(r => !r.complete));
  assert.equal(all.find(r => r.end_reason === 'data_gap').end, null);
  assert.equal(all.find(r => r.end_reason === 'parked').start, null);
}));

test('battery traffic cannot mask a state gap or manufacture completed start/end', () => using((db, id) => {
  ingest(db, id, [gear('p', 0, 'P'), gear('d', 10, 'D'), ...[60, 120, 180, 240].map((t, i) => p(`b${i}`, t, { battery_percent: valid(80 - i) })), gear('end', 250, 'P')]);
  const record = detail(db)[0]; assert.equal(record.end_reason, 'data_gap'); assert.equal(record.end, null); assert.equal(record.complete, false);
  ingest(db, id, [gear('d2', 500, 'D'), gear('p2', 520, 'P')]);
  assert.equal(detail(db).find(r => r.end === at(520)).start, null);
}));

test('arrival order, same-time sender IDs, and batch partition do not change canonical sparse projection', () => {
  const points = [...drive(), p('b-drive', 10, { battery_percent: valid(80) }), p('b-mid', 30, { battery_percent: valid(79) })];
  const variants = [points, [...points].reverse(), [points[3], points[2], points[4], points[0], points[1]]];
  const snapshots = [];
  for (const [index, variant] of variants.entries()) using((db, id) => {
    if (index === 0) ingest(db, id, variant); else for (const point of variant) ingest(db, id, [point]);
    // Binding UUIDs are deliberately random across stores; revisions count actual updates.
    snapshots.push(detail(db).map(({ id, revision, samples, ...r }) => ({ ...r, samples: samples.map(({ id, ...s }) => s) })));
  });
  assert.deepEqual(snapshots[1], snapshots[0]); assert.deepEqual(snapshots[2], snapshots[0]);
});

test('sparse validator is bounded, trip-only, authenticated and cannot mix strict trip journals', () => using((db, id) => {
  for (const bad of [p('x', 0, {}), p('x', 0, { gear: { valid: false, value: 'P' } }),
    p('x', 0, { gear: valid('X') }), p('x', 0, { battery_percent: valid(null) }), p('x', 0, { battery_percent: valid(101) }),
    p('x', 0, { gear: { valid: 'true', value: 'D' } }), p('x', 0, { speed_kph: valid(20) }),
    { ...gear('x', 0, 'D'), kind: 'charge' }, { ...gear('x', 0, 'D'), account: 'attacker' },
    { ...gear('x', 0, 'D'), at: new Date(NOW + 1).toISOString() },
    { ...gear('x', 0, 'D'), at: new Date(NOW - RETENTION_MS).toISOString() }]) assert.throws(() => ingest(db, id, [bad]));
  assert.throws(() => ingest(db, id, []));
  assert.throws(() => ingest(db, id, Array(CAPTURE_LIMITS.batch + 1).fill(gear('x', 0, 'D'))));
  assert.throws(() => ingest(db, id, [{ ...gear('x', 0, 'D'), extra: 'x'.repeat(CAPTURE_LIMITS.bytes) }]), { status: 413 });
  assert.throws(() => db.ingestPatches({ vin: VIN, stream: 'sparse-fixture' }, id, drive()), { status: 401 });
  db.authenticateReceiver = c => c === 'wrong' ? { vin: VIN, stream: 'other' } : options().authenticateReceiver(c);
  assert.throws(() => db.ingestPatches('wrong', id, drive()), { status: 403 });
  ingest(db, id, drive());
  assert.throws(() => db.ingest('receiver', id, [{ id: 'strict', kind: 'trip', at: at(100), gear: 'D' }]), { status: 409 });
  assert.equal(db.list('other-account', { vin: VIN }).records.length, 0);
}));

test('strict-first journal rejects sparse patches rather than silently merging semantics', () => using((db, id) => {
  db.ingest('receiver', id, [{ id: 'strict', kind: 'trip', at: at(10), gear: 'D' }]);
  assert.throws(() => ingest(db, id, drive()), { status: 409 });
  assert.equal(db.db.prepare('SELECT count(*) AS n FROM patches').get().n, 0);
}));

test('sparse shared journal capacity rolls back insertion; identical retry works at capacity', () => using((db, id) => {
  db.transaction(() => {
    const put = db.db.prepare('INSERT INTO patches VALUES(?,?,?,?)');
    for (let i = 0; i < CAPTURE_LIMITS.eventsPerBinding; i++) {
      const point = gear(`capacity-${i}`, -i, 'P'); put.run(id, point.id, Date.parse(point.at), JSON.stringify(point));
    }
  });
  assert.equal(ingest(db, id, [gear('capacity-0', 0, 'P')]).duplicates, 1);
  assert.throws(() => ingest(db, id, [gear('overflow', 10, 'D')]), { status: 429 });
  assert.equal(db.db.prepare('SELECT count(*) AS n FROM patches').get().n, CAPTURE_LIMITS.eventsPerBinding);
}));

test('deleting pending interval suppresses resends, delete-all floors other binding backfill, expiry/revoke deny ingest', () => {
  let now = NOW; const db = new NativeCaptureStore(':memory:', options(() => now));
  try {
    const id = bind(db); const points = drive().slice(0, 2); ingest(db, id, points);
    db.deleteRecord('owner', VIN, rows(db)[0].id);
    assert.equal(ingest(db, id, points).suppressed, 1); assert.equal(rows(db).length, 0);
    assert.equal(db.db.prepare('SELECT count(*) AS n FROM patches').get().n, 1);
    ingest(db, id, [gear('new', 200, 'D')]); db.deleteAll('owner', VIN);
    assert.equal(db.db.prepare('SELECT count(*) AS n FROM patches').get().n, 0);
    assert.equal(ingest(db, id, [gear('new', 200, 'D')]).suppressed, 1);
    now += 60001; assert.throws(() => ingest(db, id, points), { status: 403 });
    assert.equal(bind(db), id); assert.equal(ingest(db, id, points).suppressed, 2);
    db.revoke('owner', id); assert.throws(() => ingest(db, id, points), { status: 403 });
  } finally { db.close(); }
});

test('sparse retention removes pending raw journal and records; old resend is rejected', () => {
  let now = NOW; const db = new NativeCaptureStore(':memory:', options(() => now));
  try {
    const id = bind(db); ingest(db, id, drive().slice(0, 2)); now += RETENTION_MS;
    assert.equal(rows(db).length, 0); assert.equal(db.db.prepare('SELECT count(*) AS n FROM patches').get().n, 0);
    assert.throws(() => ingest(db, id, drive()));
  } finally { db.close(); }
});

test('actual child exits after journal COMMIT and after replay; reopen and resend preserve identity/count/revision', () => {
  const dir = mkdtempSync(join(tmpdir(), 'pony-sparse-crash-')), path = join(dir, 'capture.sqlite'); let db;
  try {
    db = new NativeCaptureStore(path, options()); const id = bind(db);
    ingest(db, id, drive().slice(0, 2)); const original = rows(db)[0].id; db.close(); db = null;
    for (const phase of ['journal', 'replay']) {
      const point = phase === 'journal' ? p('crash-battery', 10, { battery_percent: valid(80) }) : gear('end', 90, 'P');
      const child = spawnSync(process.execPath, ['--input-type=module', '-e', `
        import { NativeCaptureStore } from ${JSON.stringify(new URL('./native-capture.mjs', import.meta.url).href)};
        const db = new NativeCaptureStore(${JSON.stringify(path)}, {
          clock: () => ${NOW}, authenticateReceiver: () => ({ vin: ${JSON.stringify(VIN)}, stream: 'sparse-fixture' })
        });
        ${phase === 'journal' ? 'db.replay = () => process.exit(73);' : ''}
        db.ingestPatches('receiver', ${JSON.stringify(id)}, [${JSON.stringify(point)}]);
        // No external spool receipt can be written before this abrupt exit.
        process.exit(74);
      `], { encoding: 'utf8' });
      assert.equal(child.status, phase === 'journal' ? 73 : 74, child.stderr);
      db = new NativeCaptureStore(path, options());
      assert.equal(rows(db).length, 1); assert.equal(rows(db)[0].id, original);
      const before = db.detail('owner', VIN, original);
      assert.equal(ingest(db, id, [point]).duplicates, 1);
      assert.deepEqual(db.detail('owner', VIN, original), before);
      db.close(); db = null;
    }
    db = new NativeCaptureStore(path, options()); assert.equal(rows(db)[0].complete, true);
  } finally { db?.close(); rmSync(dir, { recursive: true, force: true }); }
});

test('schema v1 upgrade preserves strict records; v2 presence journal is durable', () => {
  const dir = mkdtempSync(join(tmpdir(), 'pony-sparse-schema-')), path = join(dir, 'capture.sqlite'); let db;
  try {
    db = new NativeCaptureStore(path, options()); const id = bind(db);
    db.ingest('receiver', id, [{ id: 'strict', kind: 'trip', at: at(10), gear: 'D' }]);
    const before = detail(db); db.close(); db = null;
    const legacy = new DatabaseSync(path); legacy.exec('DROP TABLE patches; PRAGMA user_version=1'); legacy.close();
    db = new NativeCaptureStore(path, options()); assert.deepEqual(detail(db), before);
    assert.equal(db.db.prepare('PRAGMA user_version').get().user_version, 2);
    assert.equal(db.db.prepare('SELECT count(*) AS n FROM patches').get().n, 0);
  } finally { db?.close(); rmSync(dir, { recursive: true, force: true }); }
});

test('offline exporter emits actual list/detail DTOs and byte SHA manifest from a patches file', () => {
  const dir = mkdtempSync(join(tmpdir(), 'pony-sparse-export-'));
  try {
    const input = join(dir, 'patches.json'), output = join(dir, 'dto');
    // The exporter consumes this file; it never generates substitute input patches.
    const { writeFileSync } = awaitImportNotNeeded;
  } finally { rmSync(dir, { recursive: true, force: true }); }
});
