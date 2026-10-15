import test, { before, after } from 'node:test';
import assert from 'node:assert/strict';
import https from 'node:https';
import http from 'node:http';
import net from 'node:net';
import { execFileSync } from 'node:child_process';
import { mkdtemp, readFile, rm, mkdir } from 'node:fs/promises';
import { tmpdir } from 'node:os';
import { join } from 'node:path';
import { chromium } from 'playwright';
import { createApp } from '../backend/server.mjs';
import { TeslaClient, Vault, AUTH, FLEET } from '../backend/core.mjs';
import { HistoryStore } from '../backend/history.mjs';

const vin = 'LRW3E7FA0NC123456';
let browser, temp, tls;
before(async () => {
  temp = await mkdtemp(join(tmpdir(), 'pony-browser-'));
  execFileSync('openssl', ['req', '-x509', '-newkey', 'rsa:2048', '-nodes', '-keyout', join(temp, 'key.pem'),
    '-out', join(temp, 'cert.pem'), '-days', '1', '-subj', '/CN=localhost'], { stdio: 'ignore' });
  tls = { key: await readFile(join(temp, 'key.pem')), cert: await readFile(join(temp, 'cert.pem')) };
  browser = await chromium.launch({ headless: true });
});
after(async () => { await browser?.close(); if (temp) await rm(temp, { recursive: true, force: true }); });

async function fixture(action, { missing = [], authorized = false, mobile = false } = {}) {
  const dir = await mkdtemp(join(temp, 'case-'));
  const settings = { missing, clientId: 'browser-fixture-client', clientSecret: 'browser-fixture-secret',
    key: 'b'.repeat(64), adminPassword: 'a'.repeat(64), dir };
  const vault = new Vault(dir, settings.key);
  if (authorized) await vault.write({ access_token: 'browser-access', refresh_token: 'browser-refresh', expires_at: Date.now() + 3600000 });
  const scenario = { vehicles: [{ vin, display_name: '测试 Model 3', state: 'online' }], listError: false };
  const calls = [];
  const client = new TeslaClient(settings, vault, async (url, options) => {
    calls.push({ url, method: options.method });
    let value;
    if (url === `${AUTH}/token`) {
      assert.equal(options.body.get('code'), 'browser-fixture-code');
      value = { access_token: 'browser-access', refresh_token: 'browser-refresh', expires_in: 3600 };
    } else if (url === `${FLEET}/api/1/vehicles`) {
      if (scenario.listError) return new Response('private Tesla diagnostics', { status: 503 });
      value = { response: scenario.vehicles };
    } else if (url === `${FLEET}/api/1/vehicles/fleet_status`) value = { response: { vehicle_command_protocol_required: true } };
    else if (url.startsWith(`${FLEET}/api/1/vehicles/${vin}/vehicle_data?`)) value = { response: { charge_state: { battery_level: 61 }, climate_state: { inside_temp: 23 }, drive_state: { speed: 0 } } };
    else throw new Error('Unexpected fixture API request');
    return new Response(JSON.stringify(value));
  });
  const history = new HistoryStore(join(dir, 'history.sqlite'), { allowSimulation: true });
  const app = createApp(settings, missing.length ? null : client, vault, history);
  const server = https.createServer(tls, app.listeners('request')[0]);
  await new Promise(resolve => server.listen(0, '127.0.0.1', resolve));
  settings.origin = `https://127.0.0.1:${server.address().port}`;
  const authServer = https.createServer(tls, (req, res) => {
    const url = new URL(req.url, 'https://auth.tesla.cn');
    if (url.pathname !== '/oauth2/v3/authorize' || url.searchParams.get('redirect_uri') !== `${settings.origin}/oauth/callback`) {
      res.writeHead(400); return res.end('Unexpected fixture authorization request');
    }
    const state = encodeURIComponent(url.searchParams.get('state'));
    res.writeHead(200, { 'Content-Type': 'text/html; charset=utf-8' });
    res.end(`<html><body><a href="${settings.origin}/oauth/callback?state=${state}&code=browser-fixture-code">同意测试授权</a><a href="${settings.origin}/oauth/callback?state=${state}&error=access_denied">取消测试授权</a></body></html>`);
  });
  await new Promise(resolve => authServer.listen(0, '127.0.0.1', resolve));
  // A deny-by-default proxy covers redirects as well as initial requests. Browser
  // route interception alone does not reliably intercept redirected navigations.
  const proxy = http.createServer((req, res) => { res.writeHead(403); res.end(); });
  const sockets = new Set();
  proxy.on('connect', (req, socket, head) => {
    const port = req.url === 'auth.tesla.cn:443' ? authServer.address().port
      : req.url === `127.0.0.1:${server.address().port}` ? server.address().port : null;
    if (!port) return socket.destroy();
    const upstream = net.connect(port, '127.0.0.1', () => {
      socket.write('HTTP/1.1 200 Connection Established\r\n\r\n');
      if (head.length) upstream.write(head);
      socket.pipe(upstream); upstream.pipe(socket);
    });
    for (const connection of [socket, upstream]) {
      sockets.add(connection); connection.on('close', () => sockets.delete(connection));
      connection.on('error', () => { socket.destroy(); upstream.destroy(); });
    }
  });
  await new Promise(resolve => proxy.listen(0, '127.0.0.1', resolve));
  const context = await browser.newContext({ ignoreHTTPSErrors: true,
    proxy: { server: `http://127.0.0.1:${proxy.address().port}` },
    httpCredentials: { username: 'owner', password: settings.adminPassword, origin: settings.origin },
    viewport: mobile ? { width: 390, height: 844 } : { width: 1280, height: 900 },
    ...(mobile ? { isMobile: true, hasTouch: true, deviceScaleFactor: 3 } : {}) });
  const page = await context.newPage();
  page.setDefaultTimeout(5000);
  const errors = [];
  const diagnostics = [];
  page.on('pageerror', error => errors.push(error.message));
  page.on('console', message => { if (message.type() === 'error') diagnostics.push(message.text()); });
  try {
    await page.goto(settings.origin);
    await page.waitForFunction(() => !document.querySelector('#status').textContent.includes('正在检查'));
    await action({ page, context, settings, scenario, calls, vault, history });
    assert.deepEqual(errors, []);
  } catch (error) {
    throw new Error(`${error.message}\nFixture URL: ${page.url()}\nBrowser diagnostics: ${diagnostics.join('; ')}\nPage: ${(await page.locator('body').innerText().catch(() => '')).slice(0,1200)}`, { cause: error });
  } finally {
    await context.close();
    for (const socket of sockets) socket.destroy();
    for (const service of [server, authServer, proxy]) {
      service.closeAllConnections(); await new Promise(resolve => service.close(resolve));
    }
    history.close();
  }
}

test('unconfigured application explains missing credentials and disables unavailable actions', async () => fixture(async ({ page, calls }) => {
  assert.match(await page.locator('#status').innerText(), /TESLA_CLIENT_ID/);
  for (const id of ['connect', 'list', 'probe']) assert.equal(await page.locator(`#${id}`).isDisabled(), true);
  assert.equal(calls.length, 0);
}, { missing: ['TESLA_CLIENT_ID', 'TESLA_CLIENT_SECRET'] }));

test('browser completes OAuth, stores encrypted tokens, lists vehicles and reads live data', async () => fixture(async ({ page, settings, vault, context, calls }) => {
  await page.locator('#connect').click();
  await page.getByText('同意测试授权').click();
  await page.waitForURL(`${settings.origin}/`);
  await page.waitForFunction(() => document.querySelector('#status').textContent.includes('已保存 Tesla 授权'));
  assert.equal((await vault.read()).access_token, 'browser-access');
  const raw = await readFile(join(settings.dir, 'tokens.enc.json'), 'utf8');
  assert.ok(!raw.includes('browser-access'));
  assert.equal((await context.cookies()).some(cookie => cookie.name === 'pony_oauth'), false);
  await page.locator('#list').click();
  await page.waitForFunction(() => !document.querySelector('#probe').disabled);
  assert.match(await page.locator('#vehicles').innerText(), /测试 Model 3/);
  await page.locator('#probe').click();
  await page.waitForFunction(() => document.querySelector('#result').textContent.includes('battery_level'));
  const data = JSON.parse(await page.locator('#result').innerText());
  assert.equal(data.data.charge_state.battery_level, 61);
  assert.equal(data.live_data, true);
  await page.locator('#probe').click();
  await page.waitForFunction(() => document.querySelector('#result').textContent.includes('15 秒'));
  assert.equal(calls.filter(call => call.url.includes('/vehicle_data?')).length, 1);
  assert.ok(!(await page.locator('body').innerText()).includes('browser-access'));
}));

test('cancelled consent can be retried without pretending authorization succeeded', async () => fixture(async ({ page, settings, vault, calls }) => {
  await page.locator('#connect').click();
  await page.getByText('取消测试授权').click();
  await page.waitForURL('**/oauth/callback?**');
  assert.match(await page.locator('body').innerText(), /授权未完成/);
  assert.equal(await vault.read(), null);
  assert.equal(calls.length, 0);
  await page.goto(settings.origin);
  await page.locator('#connect').click();
  await page.getByText('同意测试授权').click();
  await page.waitForFunction(() => document.querySelector('#status')?.textContent.includes('已保存 Tesla 授权'));
}));

test('offline vehicle is clearly reported and never receives a wake or live-data request', async () => fixture(async ({ page, scenario, calls }) => {
  scenario.vehicles[0].state = 'asleep';
  await page.locator('#list').click();
  await page.locator('#probe').click();
  await page.waitForFunction(() => document.querySelector('#result').textContent.includes('当前不在线'));
  assert.equal(JSON.parse(await page.locator('#result').innerText()).live_data, false);
  assert.equal(calls.some(call => /wake_up|vehicle_data|\/command\//.test(call.url)), false);
}, { authorized: true }));

test('empty account keeps read disabled and explains that no vehicles are authorized', async () => fixture(async ({ page, scenario }) => {
  scenario.vehicles = [];
  await page.locator('#list').click();
  await page.waitForFunction(() => document.querySelector('#result').textContent.includes('没有车辆'));
  assert.equal(await page.locator('#probe').isDisabled(), true);
}, { authorized: true }));

test('failed vehicle refresh clears stale selection, disables reading, and can recover', async () => fixture(async ({ page, scenario }) => {
  await page.locator('#list').click();
  await page.waitForFunction(() => !document.querySelector('#probe').disabled);
  scenario.listError = true;
  await page.locator('#list').click();
  await page.waitForFunction(() => document.querySelector('#result').textContent.includes('503'));
  assert.equal(await page.locator('#probe').isDisabled(), true);
  assert.equal(await page.locator('#vehicles option').count(), 0);
  assert.ok(!(await page.locator('#result').innerText()).includes('private Tesla diagnostics'));
  scenario.listError = false;
  await page.locator('#list').click();
  await page.waitForFunction(() => !document.querySelector('#probe').disabled);
}, { authorized: true }));

test('mobile viewport supports vehicle selection and data without horizontal overflow', async () => fixture(async ({ page }) => {
  await page.locator('#list').click();
  await page.locator('#probe').click();
  await page.waitForFunction(() => document.querySelector('#result').textContent.includes('battery_level'));
  assert.equal(await page.evaluate(() => document.documentElement.scrollWidth <= innerWidth), true);
  await mkdir('artifacts/test-results', { recursive: true });
  await page.screenshot({ path: 'artifacts/test-results/mobile-connection.png', fullPage: true });
}, { authorized: true, mobile: true }));

test('readiness and empty server history are clear before Tesla authorization', async () => fixture(async ({ page, calls }) => {
  await page.waitForFunction(() => document.querySelector('#connection-steps').textContent.includes('持续采集：未接通'));
  assert.match(await page.locator('#connection-steps').innerText(), /车主授权：未授权/);
  assert.match(await page.locator('#history-status').innerText(), /0 段行程/);
  await page.locator('#history-refresh').click();
  await page.waitForFunction(() => document.querySelector('#trip-result').textContent.includes('服务器尚无行程'));
  assert.equal(await page.locator('#trip-open').isDisabled(), true);
  assert.equal(calls.length, 0);
}, { missing: ['TESLA_CLIENT_ID', 'TESLA_CLIENT_SECRET'] }));

test('browser queries persisted synthetic history and exposes only its selected CSV', async () => fixture(async ({ page, history, calls }) => {
  const start = Date.now() - 3600000;
  history.ingest(vin, 'simulation', [0, 60, 120].map((offset, i) => ({ at: new Date(start + offset * 1000).toISOString(),
    gear: i === 2 ? 'P' : 'D', speed_kph: 30, power_kw: 10, odometer_km: 500 + i / 2 })));
  await page.locator('#history-refresh').click();
  await page.waitForFunction(() => !document.querySelector('#trip-open').disabled);
  assert.match(await page.locator('#trips').innerText(), /模拟数据/);
  await page.locator('#trip-open').click();
  await page.waitForFunction(() => !document.querySelector('#trip-export').hidden);
  const trip = JSON.parse(await page.locator('#trip-result').innerText());
  assert.equal(trip.samples.length, 3);
  assert.equal(await page.locator('#trip-export').getAttribute('href'), `/api/v1/trips/${trip.id}/export.csv`);
  history.deleteTrip(trip.id);
  await page.locator('#history-refresh').click();
  await page.waitForFunction(() => document.querySelector('#trip-result').textContent.includes('服务器尚无行程'));
  assert.equal(await page.locator('#trip-export').isVisible(), false);
  assert.equal(calls.length, 0);
}, { missing: ['TESLA_CLIENT_ID', 'TESLA_CLIENT_SECRET'] }));
