// Finite macOS-only orchestrator. Inherits the caller's Node 24 PATH.
import { spawn } from 'node:child_process';
import { mkdtemp, rm, readFile } from 'node:fs/promises';
import { tmpdir } from 'node:os';
import { join, dirname } from 'node:path';
import { fileURLToPath } from 'node:url';
const here = dirname(fileURLToPath(import.meta.url));
if (process.platform !== 'darwin' || Number(process.versions.node.split('.')[0]) < 24) throw new Error('Requires macOS and Node 24+');
process.umask(0o077);
const dir = await mkdtemp(join(tmpdir(), 'synthetic-owner-wk-'));
const children = new Set();
let expired = false;
const launch = (command, args, options = {}) => {
  const child = spawn(command, args, { stdio: 'ignore', ...options });
  children.add(child);
  child.done = new Promise(resolve => { child.once('error', () => resolve(127)); child.once('exit', code => resolve(code ?? 1)); });
  child.once('exit', () => children.delete(child));
  return child;
};
const run = async (command, args, options) => {
  if (expired) throw new Error('deadline');
  if (await launch(command, args, options).done !== 0) throw new Error('child failed');
};
const stop = () => { expired = true; for (const child of children) child.kill('SIGKILL'); };
const deadline = setTimeout(stop, 58000);
process.on('SIGINT', stop); process.on('SIGTERM', stop);
let code = 1;
try {
  await run('openssl', ['req', '-x509', '-newkey', 'rsa:2048', '-nodes', '-keyout', `${dir}/key.pem`, '-out', `${dir}/cert.pem`, '-days', '1', '-subj', '/CN=127.0.0.1', '-addext', 'subjectAltName=IP:127.0.0.1']);
  await run('openssl', ['x509', '-in', `${dir}/cert.pem`, '-outform', 'DER', '-out', `${dir}/cert.der`]);
  // Compilation output is safe source-only diagnostic text, never fixture URL data.
  await run('swiftc', ['-swift-version', '5', join(here, 'Browser.swift'), '-o', `${dir}/browser`], { stdio: ['ignore', 'inherit', 'inherit'] });
  const fixture = launch(process.execPath, [join(here, 'fixture.mjs'), dir], { stdio: ['ignore', 'ignore', 'ignore', 'ipc'] });
  await Promise.race([
    new Promise(resolve => fixture.once('message', resolve)),
    fixture.done.then(() => { throw new Error('fixture stopped'); })
  ]);
  await run(`${dir}/browser`, [dir, 'synthetic-fixture-only'], { stdio: ['ignore', 'inherit', 'ignore'] });
  const evidence = JSON.parse(await readFile(`${dir}/evidence.json`, 'utf8'));
  if (!evidence.originAccepted || !evidence.cookieAccepted || !evidence.callbackStateValid || !evidence.grantCreated || !evidence.statuses.includes(200) || !evidence.statuses.includes(303)) throw new Error('missing server evidence');
  console.log('PASS SYNTHETIC ONLY macOS WKWebView owner browser integration');
  code = 0;
} catch { console.error('FAIL SYNTHETIC ONLY WKWebView integration (details redacted; check compile diagnostics / browser booleans)'); }
finally {
  clearTimeout(deadline);
  const pending = [...children];
  for (const child of pending) child.kill('SIGKILL');
  await Promise.all(pending.map(child => child.done));
  // Print only an explicit safe schema, even after a failed browser child.
  try {
    const e = JSON.parse(await readFile(`${dir}/evidence.json`, 'utf8'));
    console.log(JSON.stringify({ serverEvidence: {
      statuses: Array.isArray(e.statuses) ? e.statuses.filter(n => Number.isInteger(n) && n >= 100 && n <= 599) : [],
      originAccepted: e.originAccepted === true,
      cookieAccepted: e.cookieAccepted === true,
      callbackStateValid: e.callbackStateValid === true,
      grantCreated: e.grantCreated === true
    } }));
  } catch { console.log(JSON.stringify({ serverEvidenceAvailable: false })); }
  await rm(dir, { recursive: true, force: true });
}
process.exit(code);
