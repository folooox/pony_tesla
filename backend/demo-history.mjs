import assert from 'node:assert/strict';
import { mkdtemp, rm } from 'node:fs/promises';
import { tmpdir } from 'node:os';
import { join } from 'node:path';
import { HistoryStore } from './history.mjs';
import { createApp } from './server.mjs';

// Always isolated: no .env, no production path, no Tesla client and no public listen address.
const dir = await mkdtemp(join(tmpdir(), 'pony-history-demo-'));
const history = new HistoryStore(join(dir, 'history.sqlite'), { allowSimulation: true });
const settings = { missing: ['TESLA_CLIENT_ID', 'TESLA_CLIENT_SECRET'], adminPassword: 'isolated-demo-password-'.repeat(3), origin: 'https://demo.invalid' };
const server = createApp(settings, null, null, history);
try {
  const start = Date.now() - 30 * 60 * 1000;
  const samples = Array.from({ length: 61 }, (_, i) => ({ at: new Date(start + i * 10000).toISOString(), gear: i === 60 ? 'P' : 'D',
    speed_kph: i === 30 || i === 60 ? 0 : 36, power_kw: i % 8 === 0 ? -3 : 12, battery_percent: 80 - i / 20,
    odometer_km: 20000 + i / 10, latitude: 31.2 + i / 10000, longitude: 121.4 + i / 10000 }));
  assert.equal(history.ingest('LRW3E7FA0NC123456', 'simulation', samples).inserted, 1);
  await new Promise(resolve => server.listen(0, '127.0.0.1', resolve));
  const base = `http://127.0.0.1:${server.address().port}`;
  const headers = { authorization: `Basic ${Buffer.from(`owner:${settings.adminPassword}`).toString('base64')}` };
  const list = await (await fetch(`${base}/api/v1/trips`, { headers })).json();
  assert.equal(list.trips.length, 1);
  const { trip } = await (await fetch(`${base}/api/v1/trips/${list.trips[0].id}`, { headers })).json();
  assert.equal(trip.samples.length, 61);
  const csv = await (await fetch(`${base}/api/v1/trips/${trip.id}/export.csv`, { headers })).text();
  assert.ok(csv.includes('simulation'));
  console.log('PASS 61 normalized simulation samples → SQLite → authenticated HTTP list/detail/CSV');
  console.log('No Tesla connection, no production data, temporary database removed on exit.');
} finally {
  server.closeAllConnections();
  if (server.listening) await new Promise(resolve => server.close(resolve));
  history.close(); await rm(dir, { recursive: true, force: true });
}
