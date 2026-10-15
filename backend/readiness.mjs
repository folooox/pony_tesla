import { createHash, randomBytes } from 'node:crypto';
import { readFile, writeFile, rename, rm, mkdir } from 'node:fs/promises';
import { join } from 'node:path';
import { FLEET } from './core.mjs';
const digest = value => createHash('sha256').update(value).digest('hex');

export async function saveRegistration(settings, publicKey) {
  await mkdir(settings.dir, { recursive: true, mode: 0o700 });
  const receipt = { registered_at: new Date().toISOString(), origin: settings.origin, region: FLEET,
    client_hash: digest(settings.clientId), public_key_hash: digest(publicKey.trim()) };
  const path = join(settings.dir, 'registration.json');
  const temporary = `${path}.${randomBytes(8).toString('hex')}.tmp`;
  try { await writeFile(temporary, JSON.stringify(receipt), { mode: 0o600, flag: 'wx' }); await rename(temporary, path); }
  finally { await rm(temporary, { force: true }); }
}

export async function readiness(settings, vault, history) {
  const token = vault ? await vault.read() : null;
  let publicKey = null;
  let registration = { status: 'not_recorded', detail: '未记录中国区注册成功结果' };
  if (settings.dir) {
    try { publicKey = await readFile(join(settings.dir, 'public-key.pem'), 'utf8'); }
    catch (error) { if (error.code !== 'ENOENT') throw error; }
    try {
      const receipt = JSON.parse(await readFile(join(settings.dir, 'registration.json'), 'utf8'));
      const matches = settings.clientId && publicKey && receipt.origin === settings.origin && receipt.region === FLEET
        && receipt.client_hash === digest(settings.clientId) && receipt.public_key_hash === digest(publicKey.trim())
        && typeof receipt.registered_at === 'string' && Number.isFinite(Date.parse(receipt.registered_at));
      registration = matches ? { status: 'recorded', registered_at: receipt.registered_at, detail: '本地记录曾注册成功，未再次向 Tesla 验证当前状态' }
        : { status: 'configuration_changed', detail: '注册记录与当前域名、应用或公钥不匹配，需重新核验注册' };
    } catch (error) {
      if (error.code !== 'ENOENT') registration = { status: 'unreadable', detail: '注册记录无法读取，不能判断已注册' };
    }
  }
  return {
    api_version: 1, mode: 'single_owner_connection_test',
    origin: settings.origin ?? null, callback: settings.origin ? `${settings.origin}/oauth/callback` : null,
    missing: settings.missing,
    stages: {
      configuration: { status: settings.missing.length ? 'missing' : 'configured', detail: '配置存在不等于 Tesla 已验证凭据' },
      public_key: { status: publicKey ? 'present' : 'missing', detail: '本地公钥状态；公网解析与 HTTPS 另由部署检查验证' },
      registration,
      authorization: { status: token ? 'token_saved' : 'not_authorized', detail: token ? '保存过车主令牌，当前有效性需真实请求验证' : '等待在 Tesla 官方页面登录授权' },
      history: { status: history ? 'available' : 'not_enabled', ...(history ? history.stats() : {}) },
      telemetry: { status: 'not_connected', detail: '尚未部署真实遥测接收与车辆配置；历史 API 可用不等于已在采集' },
      native_session: { status: 'not_implemented', detail: '当前为受保护的单车主测试后台，尚未提供原生 App 用户会话' }
    }
  };
}
