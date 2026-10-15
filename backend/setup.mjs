import { generateKeyPairSync, randomBytes } from 'node:crypto';
import { mkdir, writeFile, access } from 'node:fs/promises';

for (const path of ['.env', '.private']) {
  try { await access(path); console.error('配置或密钥目录已存在；为避免覆盖，请继续使用原配置。'); process.exit(1); }
  catch (e) { if (e.code !== 'ENOENT') throw e; }
}
await mkdir('.private', { mode: 0o700 });
const keys = generateKeyPairSync('ec', { namedCurve: 'prime256v1',
  publicKeyEncoding: { type: 'spki', format: 'pem' }, privateKeyEncoding: { type: 'pkcs8', format: 'pem' } });
await writeFile('.private/private-key.pem', keys.privateKey, { mode: 0o600, flag: 'wx' });
await writeFile('.private/public-key.pem', keys.publicKey, { mode: 0o600, flag: 'wx' });
await writeFile('.env', `TESLA_CLIENT_ID=\nTESLA_CLIENT_SECRET=\nPUBLIC_ORIGIN=\nADMIN_PASSWORD=${randomBytes(32).toString('hex')}\nTOKEN_ENCRYPTION_KEY=${randomBytes(32).toString('hex')}\nPORT=8787\nNODE_USE_ENV_PROXY=1\n`, { mode: 0o600, flag: 'wx' });
console.log('已生成 .env 和 .private/，未输出任何密钥。请在本地编辑器中完成应用配置；后台账号名为 owner。');
