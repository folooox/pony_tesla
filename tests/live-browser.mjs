import assert from 'node:assert/strict';
import { chromium } from 'playwright';
import { config } from '../backend/core.mjs';

// Explicitly invoked passive checks against the deployed site; no login/vehicle buttons are clicked.
const settings = config();
if (!settings.origin || !settings.adminPassword) throw new Error('Deployment origin and owner password required.');
const browser = await chromium.launch({ headless: true });
try {
  for (const viewport of [{ width: 1280, height: 900 }, { width: 390, height: 844 }]) {
    const context = await browser.newContext({ viewport,
      httpCredentials: { username: 'owner', password: settings.adminPassword, origin: settings.origin } });
    // Do not ignore certificate errors on the public site.
    const page = await context.newPage();
    const errors = [];
    page.on('pageerror', error => errors.push(error.message));
    await page.goto(settings.origin);
    await page.waitForFunction(() => !document.querySelector('#status').textContent.includes('正在检查'));
    await page.waitForFunction(() => document.querySelector('#connection-steps').textContent.includes('历史存储：已启用'));
    assert.match(await page.title(), /Pony Tesla/);
    assert.equal(await page.evaluate(() => document.documentElement.scrollWidth <= innerWidth), true);
    const status = await page.evaluate(async () => (await fetch('/api/status')).json());
    assert.equal(await page.locator('#connect').isDisabled(), status.missing.length > 0);
    assert.equal(await page.locator('#list').isDisabled(), !status.authorized);
    assert.equal(await page.locator('#probe').isDisabled(), true);
    assert.match(await page.locator('#connection-steps').innerText(), /持续采集：未接通/);
    assert.match(await page.locator('#history-status').innerText(), /保留 168 小时/);
    assert.deepEqual(errors, []);
    console.log(`PASS live HTTPS page at ${viewport.width}x${viewport.height}; no browser errors`);
    await context.close();
  }
} finally { await browser.close(); }
