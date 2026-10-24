import { randomBytes, createCipheriv, createDecipheriv } from 'node:crypto';
import { readFile, writeFile, mkdir, rename, rm } from 'node:fs/promises';
import { join } from 'node:path';

export const AUTH = 'https://auth.tesla.cn/oauth2/v3';
export const FLEET = 'https://fleet-api.prd.cn.vn.cloud.tesla.cn';
export const SCOPES = 'openid offline_access vehicle_device_data vehicle_location';
export const NATIVE_SCOPES = `${SCOPES} vehicle_cmds`;
// Internal status evidence only; never infer denial from a message or token claims.
const upstreamStatus = new WeakMap();
export const isRecord = value => value !== null && typeof value === 'object' && !Array.isArray(value);
export const validVin = value => typeof value === 'string' && /^[A-HJ-NPR-Z0-9]{17}$/.test(value);

export class SafeError extends Error {
  constructor(message, status = 400) { super(message); this.status = status; }
}

export function config(env = process.env) {
  const missing = ['TESLA_CLIENT_ID', 'TESLA_CLIENT_SECRET', 'PUBLIC_ORIGIN',
    'ADMIN_PASSWORD', 'TOKEN_ENCRYPTION_KEY'].filter(k => !env[k]);
  if (env.PUBLIC_ORIGIN) {
    let url;
    try { url = new URL(env.PUBLIC_ORIGIN); } catch { throw new SafeError('PUBLIC_ORIGIN 格式无效'); }
    if (url.protocol !== 'https:' || url.username || url.password || url.search || url.hash || url.pathname !== '/') {
      throw new SafeError('PUBLIC_ORIGIN 必须是没有路径的 HTTPS 域名');
    }
  }
  if (env.TOKEN_ENCRYPTION_KEY && !/^[a-f0-9]{64}$/i.test(env.TOKEN_ENCRYPTION_KEY)) {
    throw new SafeError('TOKEN_ENCRYPTION_KEY 必须是 32 字节十六进制密钥');
  }
  if (env.ADMIN_PASSWORD && env.ADMIN_PASSWORD.length < 32) throw new SafeError('后台测试密码至少需要 32 个字符');
  const port = Number(env.PORT || 8787);
  if (!Number.isInteger(port) || port < 1 || port > 65535) throw new SafeError('PORT 必须是 1 到 65535 之间的整数');
  return {
    missing, clientId: env.TESLA_CLIENT_ID, clientSecret: env.TESLA_CLIENT_SECRET,
    origin: env.PUBLIC_ORIGIN ? new URL(env.PUBLIC_ORIGIN).origin : undefined,
    adminPassword: env.ADMIN_PASSWORD, key: env.TOKEN_ENCRYPTION_KEY,
    port, host: env.LISTEN_HOST || '127.0.0.1', dir: '.private',
  };
}

export class Vault {
  constructor(dir, key) { this.dir = dir; this.key = Buffer.from(key, 'hex'); }
  async read() {
    let raw;
    try { raw = await readFile(join(this.dir, 'tokens.enc.json'), 'utf8'); }
    catch (e) { if (e.code === 'ENOENT') return null; throw e; }
    const { iv, tag, ciphertext } = JSON.parse(raw);
    const decipher = createDecipheriv('aes-256-gcm', this.key, Buffer.from(iv, 'hex'));
    decipher.setAuthTag(Buffer.from(tag, 'hex'));
    return JSON.parse(Buffer.concat([decipher.update(Buffer.from(ciphertext, 'base64')), decipher.final()]).toString());
  }
  async write(value) {
    await mkdir(this.dir, { recursive: true, mode: 0o700 });
    const iv = randomBytes(12);
    const cipher = createCipheriv('aes-256-gcm', this.key, iv);
    const ciphertext = Buffer.concat([cipher.update(JSON.stringify(value)), cipher.final()]);
    const target = join(this.dir, 'tokens.enc.json');
    const temporary = `${target}.${randomBytes(8).toString('hex')}.tmp`;
    try {
      await writeFile(temporary, JSON.stringify({ iv: iv.toString('hex'), tag: cipher.getAuthTag().toString('hex'), ciphertext: ciphertext.toString('base64') }), { flag: 'wx', mode: 0o600 });
      await rename(temporary, target);
    } finally { await rm(temporary, { force: true }); }
  }
}

export class OAuthStates {
  constructor() { this.pending = new Map(); }
  issue(now = Date.now()) {
    for (const [state, item] of this.pending) if (item.expires <= now) this.pending.delete(state);
    if (this.pending.size >= 50) throw new SafeError('待完成授权过多，请稍后再试', 429);
    const state = randomBytes(32).toString('hex');
    const browser = randomBytes(32).toString('hex');
    this.pending.set(state, { browser, expires: now + 600_000 });
    return { state, browser };
  }
  consume(state, browser, now = Date.now()) {
    const item = this.pending.get(state);
    if (!item || !browser || item.browser !== browser || item.expires <= now) {
      throw new SafeError('授权会话无效或已过期，请从测试页重新发起');
    }
    this.pending.delete(state);
  }
}

export async function requestJSON(url, options = {}, transport = fetch) {
  let response;
  try { response = await transport(url, { ...options, redirect: 'error', signal: AbortSignal.timeout(20_000) }); }
  catch { throw new SafeError('无法连接 Tesla，请检查网络后重试', 502); }
  if (!response.ok) {
    const hints = { 401: '授权无效或已撤销，请重新授权', 403: '应用注册或账号授权权限不足', 408: '车辆暂时不可达，请在车辆在线后重试', 429: '请求过于频繁，请稍后重试' };
    const error = new SafeError(`Tesla HTTP ${response.status}：${hints[response.status] || '请求失败，请检查官方应用配置或车辆状态'}`, 502);
    upstreamStatus.set(error, response.status);
    throw error;
  }
  try { return await response.json(); }
  catch { throw new SafeError('Tesla 返回的数据格式无效', 502); }
}

export class TeslaClient {
  constructor(settings, vault, transport = fetch) {
    this.settings = settings; this.vault = vault; this.transport = transport;
    this.queue = Promise.resolve();
  }
  // Serialize writes and refresh exchanges; refresh tokens rotate after use.
  serialized(action) {
    const pending = this.queue.then(action);
    this.queue = pending.catch(() => {});
    return pending;
  }
  authorizeURL(state) {
    const query = new URLSearchParams({ client_id: this.settings.clientId,
      redirect_uri: `${this.settings.origin}/oauth/callback`, response_type: 'code',
      scope: SCOPES, state, locale: 'zh-CN' });
    return `${AUTH}/authorize?${query}`;
  }
  async tokenRequest(params) {
    const token = await requestJSON(`${AUTH}/token`, { method: 'POST',
      headers: { 'Content-Type': 'application/x-www-form-urlencoded' },
      body: new URLSearchParams({ client_id: this.settings.clientId, ...params }),
    }, this.transport);
    if (!isRecord(token) || typeof token.access_token !== 'string' || !token.access_token.trim()
      || typeof token.refresh_token !== 'string' || !token.refresh_token.trim()
      || !Number.isFinite(token.expires_in) || token.expires_in <= 0) {
      throw new SafeError('授权结果不完整，请重新授权并允许离线访问', 502);
    }
    const stored = { access_token: token.access_token, refresh_token: token.refresh_token,
      expires_at: Date.now() + token.expires_in * 1000 };
    await this.vault.write(stored);
    return stored;
  }
  exchange(code) {
    return this.serialized(() => this.tokenRequest({ grant_type: 'authorization_code',
      client_secret: this.settings.clientSecret, audience: FLEET,
      redirect_uri: `${this.settings.origin}/oauth/callback`, code }));
  }
  accessToken() {
    return this.serialized(async () => {
      const token = await this.vault.read();
      if (!token) throw new SafeError('请先连接 Tesla 账号', 401);
      if (token.expires_at > Date.now() + 60_000) return token.access_token;
      return (await this.tokenRequest({ grant_type: 'refresh_token', refresh_token: token.refresh_token })).access_token;
    });
  }
  async api(path, body) {
    const token = await this.accessToken();
    return requestJSON(`${FLEET}${path}`, { method: body ? 'POST' : 'GET',
      headers: { Authorization: `Bearer ${token}`, ...(body ? { 'Content-Type': 'application/json' } : {}) },
      ...(body ? { body: JSON.stringify(body) } : {}),
    }, this.transport);
  }
  // Native router must durably consume the login-family claim BEFORE invoking.
  // One dispatch only: never retry on 401, refresh, timeout or ambiguous response.
  async loginWake(vin) {
    if (!validVin(vin)) throw new SafeError('请选择有效车辆');
    let token;
    try { token = await this.accessToken(); } catch { return 'wake_unknown'; }
    try {
      const result = await requestJSON(`${FLEET}/api/1/vehicles/${vin}/wake_up`, {
        method: 'POST', headers: { Authorization: `Bearer ${token}`, 'Content-Type': 'application/json' }, body: '{}',
      }, this.transport);
      // A valid wake response is acceptance, NOT evidence of live data success.
      return isRecord(result) && isRecord(result.response) && result.response.vin === vin
        && ['online', 'asleep', 'waking', 'offline', 'unknown'].includes(result.response.state)
        ? 'wake_accepted' : 'wake_unknown';
    } catch (error) { return upstreamStatus.get(error) === 403 ? 'wake_denied' : 'wake_unknown'; }
  }
  async vehicles() {
    const result = await this.api('/api/1/vehicles');
    if (!isRecord(result) || !Array.isArray(result.response) || result.response.some(car =>
      !isRecord(car) || !validVin(car.vin) || typeof car.state !== 'string'
      || (car.display_name != null && typeof car.display_name !== 'string'))) {
      throw new SafeError('车辆列表格式无效', 502);
    }
    return result.response.map(({ vin, display_name, state }) => ({ vin, display_name, state }));
  }
  async probe(vin) {
    if (!validVin(vin)) throw new SafeError('请选择有效车辆');
    const selected = (await this.vehicles()).find(vehicle => vehicle.vin === vin);
    if (!selected) throw new SafeError('车辆不在当前授权列表中', 403);
    const capability = await this.api('/api/1/vehicles/fleet_status', { vins: [vin] });
    if (!isRecord(capability) || !isRecord(capability.response)) throw new SafeError('车辆能力数据格式无效', 502);
    if (selected.state !== 'online') return { connected: true, live_data: false, vehicle: selected,
      capability: capability.response, message: '账号已连接，车辆当前不在线。请在车上或官方 App 中使车辆在线后重试。' };
    const endpoints = 'charge_state;climate_state;vehicle_state;drive_state;location_data';
    const result = await this.api(`/api/1/vehicles/${vin}/vehicle_data?endpoints=${encodeURIComponent(endpoints)}`);
    if (!isRecord(result) || !isRecord(result.response)) throw new SafeError('车况数据格式无效', 502);
    const data = result.response;
    if (!['charge_state', 'climate_state', 'vehicle_state', 'drive_state', 'location_data']
      .some(field => isRecord(data[field]) && Object.keys(data[field]).length)) {
      throw new SafeError('车辆未返回有效车况数据，不能判定读取成功', 502);
    }
    return { connected: true, live_data: true, fetched_at: new Date().toISOString(), vehicle: selected,
      capability: capability.response,
      data: { charge_state: data.charge_state, climate_state: data.climate_state,
        vehicle_state: data.vehicle_state, drive_state: data.drive_state, location_data: data.location_data },
      message: '已读取一次车况；这不代表持续行程遥测已接通。' };
  }
}
