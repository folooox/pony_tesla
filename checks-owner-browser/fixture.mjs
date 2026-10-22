// SYNTHETIC ONLY. No provider transport or real account configuration.
import https from 'node:https';
import { readFileSync, writeFileSync } from 'node:fs';
import { randomBytes } from 'node:crypto';
import { NativeAuth, CALLBACK, hash } from '../backend/native-auth.mjs';
import { OwnerPairing, ownerBrowserRouter } from '../backend/owner-pairing.mjs';
const dir = process.argv[2];
const auth = new NativeAuth(':memory:');
const settings = { nativeEnabled: true, ownerPairingEnabled: true,
  adminPassword: 'synthetic-fixture-only', key: randomBytes(32) };
const owner = new OwnerPairing(auth, settings);
const route = ownerBrowserRouter(owner, settings);
const evidence = { statuses: [], originAccepted: false, cookieAccepted: false, callbackStateValid: false, grantCreated: false };
const save = () => writeFileSync(`${dir}/evidence.json`, JSON.stringify(evidence), { mode: 0o600 });
const server = https.createServer({ key: readFileSync(`${dir}/key.pem`), cert: readFileSync(`${dir}/cert.pem`) }, async (req, res) => {
  try {
    const post = req.method === 'POST';
    res.on('finish', () => {
      evidence.statuses.push(res.statusCode);
      if (post && res.statusCode === 303) {
        evidence.originAccepted = req.headers.origin === settings.origin;
        // A 303 from the actual decide path proves the bound browser cookie was accepted.
        evidence.cookieAccepted = /(?:^|;\s*)__Secure-pony_owner=/.test(req.headers.cookie || '');
        const callback = new URL(res.getHeader('location'));
        evidence.callbackStateValid = callback.origin === new URL(CALLBACK).origin && callback.protocol === 'pony-native:' && callback.host === 'auth' && callback.searchParams.get('state') === 'synthetic_state_20261020';
        evidence.grantCreated = Boolean(callback.searchParams.get('grant')) && auth.db.prepare("SELECT count(*) AS n FROM owner_pending WHERE kind='grant'").get().n === 1;
      }
      save();
    });
    if (!await route(req, res, new URL(req.url, settings.origin))) { res.writeHead(404); res.end(); }
  } catch { res.destroy(); }
});
server.listen(0, '127.0.0.1', () => {
  settings.origin = `https://127.0.0.1:${server.address().port}`;
  const request = owner.start({ callback: CALLBACK, state: 'synthetic_state_20261020', verification_code: '12AB34CD', code_challenge: hash('synthetic_pkce_verifier_'.repeat(3)) });
  save();
  writeFileSync(`${dir}/entry.json`, JSON.stringify({ url: `${settings.origin}/owner/devices/pair?request=${request}`, origin: settings.origin }), { mode: 0o600 });
  process.send?.('ready');
});
process.on('SIGTERM', () => { server.closeAllConnections(); server.close(); auth.close(); process.exit(0); });
setTimeout(() => process.exit(2), 55000).unref();
