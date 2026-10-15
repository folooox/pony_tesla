import assert from 'node:assert/strict';
import { readFile } from 'node:fs/promises';
import { config } from '../backend/core.mjs';

// Passive checks only: this script never starts OAuth or calls a vehicle endpoint.
const settings = config();
if (!settings.origin || !settings.adminPassword) throw new Error('Configure PUBLIC_ORIGIN and ADMIN_PASSWORD before running deployment checks.');
const authorization = `Basic ${Buffer.from(`owner:${settings.adminPassword}`).toString('base64')}`;
let checks = 0;
const check = (condition, label) => { assert.ok(condition, label); checks++; console.log(`PASS ${label}`); };
const request = (path, headers = {}) => fetch(`${settings.origin}${path}`, { headers, redirect: 'manual', signal: AbortSignal.timeout(15000) });

const redirect = await fetch(`${settings.origin.replace('https:', 'http:')}/`, { redirect: 'manual', signal: AbortSignal.timeout(15000) });
check(redirect.status === 301 && redirect.headers.get('location') === `${settings.origin}/`, 'HTTP redirects to HTTPS');
const health = await request('/healthz');
check(health.ok, 'trusted public HTTPS connection');
check(health.headers.get('strict-transport-security')?.includes('max-age='), 'HTTPS HSTS header');
check(['needs_configuration', 'ready_for_authorization'].includes((await health.json()).status), 'honest readiness response');
const publicKey = await request('/.well-known/appspecific/com.tesla.3p.public-key.pem');
check(publicKey.ok && (await publicKey.text()).trim() === (await readFile(`${settings.dir}/public-key.pem`, 'utf8')).trim(), 'public Tesla key matches local key');

for (const path of ['/', '/app.js', '/style.css', '/api/status', '/api/vehicles', '/api/readiness', '/api/v1/trips', '/api/v1/history/status', '/.env', '/.private/private-key.pem', '/.private/history.sqlite']) {
  const response = await request(path);
  check(response.status === 401 && response.headers.has('www-authenticate'), `authentication required: ${path}`);
}
const statusResponse = await request('/api/status', { authorization });
check(statusResponse.status === 200 && statusResponse.headers.get('cache-control') === 'no-store', 'authenticated non-cacheable status');
const status = await statusResponse.json();
check(Array.isArray(status.missing) && typeof status.authorized === 'boolean' && status.callback === `${settings.origin}/oauth/callback`, 'status and callback configuration');
const readinessResponse = await request('/api/readiness', { authorization });
check(readinessResponse.ok, 'connection readiness endpoint available');
const readiness = await readinessResponse.json();
check(readiness.stages.history.status === 'available' && readiness.stages.history.retention_hours === 168, 'persistent history enabled with 168-hour retention');
check(readiness.stages.telemetry.status === 'not_connected' && readiness.stages.native_session.status === 'not_implemented', 'unfinished services are reported explicitly');
check(!JSON.stringify(readiness).includes(settings.adminPassword) && !('clientSecret' in readiness), 'readiness does not expose credentials');
const historyResponse = await request('/api/v1/trips?limit=1', { authorization });
check(historyResponse.ok && historyResponse.headers.get('cache-control') === 'no-store', 'private history list is available and not cacheable');
const history = await historyResponse.json();
check(Array.isArray(history.trips) && history.retention_hours === 168, 'history list contract');
const historyStatus = await request('/api/v1/history/status', { authorization });
check(historyStatus.ok && Number.isInteger((await historyStatus.json()).trips), 'history storage statistics');
for (const path of ['/', '/app.js', '/style.css']) {
  const response = await request(path, { authorization });
  const body = await response.text();
  check(response.ok && body.length > 100 && !body.includes(settings.adminPassword), `protected page asset: ${path}`);
}
for (const path of ['/.env', '/.private/private-key.pem', '/.private/history.sqlite', '/unknown']) {
  check((await request(path, { authorization })).status === 404, `private or unknown path is not served: ${path}`);
}
console.log(`${checks} deployment checks passed. Tesla authorization present: ${status.authorized}; missing configuration: ${status.missing.join(', ') || 'none'}.`);
