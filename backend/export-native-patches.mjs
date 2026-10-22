import { readFileSync, writeFileSync, mkdirSync, mkdtempSync, rmSync } from 'node:fs';
import { join, resolve } from 'node:path';
import { tmpdir } from 'node:os';
import { createHash } from 'node:crypto';
import { NativeCaptureStore, CAPTURE_LIMITS } from './native-capture.mjs';

// Offline evidence only. No HTTP server, environment credentials, Tesla client,
// car, network, or production database. The receiver is synthetic and local;
// source=telemetry exercises that DTO label, NOT authenticated live provenance.
const [inputPath, outputPath] = process.argv.slice(2);
if (!inputPath || !outputPath || process.argv.length !== 4) throw new Error('Usage: node backend/export-native-patches.mjs <Go-patches.json> <new-output-directory>');
const inputBytes = readFileSync(inputPath);
if (inputBytes.length > 16 * 1024 * 1024) throw new Error('Offline fixture exceeds 16 MiB');
const patches = JSON.parse(inputBytes.toString('utf8'));
if (!Array.isArray(patches) || !patches.length || patches.length > CAPTURE_LIMITS.eventsPerBinding) throw new Error('Expected a bounded nonempty canonical patches array');
const times = patches.map(p => Date.parse(p.at));
if (times.some(n => !Number.isFinite(n))) throw new Error('Invalid fixture timestamp');
// Use the actual fixture timeline, not the executing machine clock. Store still
// enforces the seven-day window and validates every canonical patch itself.
const now = Math.max(...times) + 1000;
const vin = 'LRW3E7FA0NC123456';
const owner = {}, operator = {}, receiver = {};
const temp = mkdtempSync(join(tmpdir(), 'pony-native-patches-'));
let store;
try {
  store = new NativeCaptureStore(join(temp, 'capture.sqlite'), {
    clock: () => now,
    authenticateAccount: context => context === owner ? 'offline-fixture-account' : null,
    authorizeOperator: context => context === operator,
    authenticateReceiver: context => context === receiver ? { vin, stream: 'offline-go-patches' } : null,
  });
  const binding = store.register(operator, { account: 'offline-fixture-account', vin, source: 'telemetry', stream: 'offline-go-patches',
    expires_at: new Date(now + 60000).toISOString() }).binding_id;
  // Honor BOTH batch bounds even for unusually long event IDs.
  let batch = [];
  const flush = () => { if (batch.length) { store.ingestPatches(receiver, binding, batch); batch = []; } };
  for (const patch of patches) {
    if (batch.length === CAPTURE_LIMITS.batch || Buffer.byteLength(JSON.stringify([...batch, patch])) > CAPTURE_LIMITS.bytes) flush();
    batch.push(patch);
  }
  flush();
  const output = resolve(outputPath);
  // Refuse existing output rather than mix current DTOs with stale evidence.
  mkdirSync(output, { mode: 0o700 }); mkdirSync(join(output, 'details'), { mode: 0o700 });
  const sha = bytes => createHash('sha256').update(bytes).digest('hex');
  const files = {};
  const emit = (name, value) => {
    const bytes = Buffer.from(JSON.stringify(value, null, 2) + '\n');
    writeFileSync(join(output, name), bytes, { flag: 'wx', mode: 0o600 }); files[name] = sha(bytes);
  };
  // Serialize the actual store DTO without wrappers or invented metrics.
  const list = store.list(owner, { vin, limit: 100 });
  if (list.next_cursor) throw new Error('Offline fixture exceeds the 100-record DTO export bound');
  emit('list.json', list);
  for (const record of list.records) emit(`details/${record.id}.json`, store.detail(owner, vin, record.id));
  const manifest = { clock: new Date(now).toISOString(), vin, files,
    input_sha256: sha(inputBytes), patch_count: patches.length, record_count: list.records.length,
    provenance: 'synthetic offline telemetry fixture; local synthetic receiver, no live authentication, network, server or car',
    source_policy: list.source_policy };
  writeFileSync(join(output, 'manifest.json'), JSON.stringify(manifest, null, 2) + '\n', { flag: 'wx', mode: 0o600 });
  console.log(JSON.stringify({ output, records: list.records.length, files: Object.keys(files).length }));
} finally {
  store?.close(); rmSync(temp, { recursive: true, force: true });
}
