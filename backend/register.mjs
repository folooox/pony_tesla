import { readFile } from 'node:fs/promises';
import { config, AUTH, FLEET, SafeError, requestJSON } from './core.mjs';
import { saveRegistration } from './readiness.mjs';

try {
  const settings = config();
  if (settings.missing.length) throw new SafeError(`请先配置：${settings.missing.join(', ')}`);
  const localKey = await readFile(`${settings.dir}/public-key.pem`, 'utf8');
  const response = await fetch(`${settings.origin}/.well-known/appspecific/com.tesla.3p.public-key.pem`, {
    redirect: 'error', signal: AbortSignal.timeout(20_000),
  });
  if (!response.ok || (await response.text()).trim() !== localKey.trim()) throw new SafeError('公网 HTTPS 公钥与本地公钥不一致');
  const token = await requestJSON(`${AUTH}/token`, { method: 'POST', headers: { 'Content-Type': 'application/x-www-form-urlencoded' },
    body: new URLSearchParams({ grant_type: 'client_credentials', client_id: settings.clientId,
      client_secret: settings.clientSecret, audience: FLEET, scope: 'vehicle_device_data' }),
  });
  if (!token.access_token) throw new SafeError('未收到合作伙伴令牌');
  await requestJSON(`${FLEET}/api/1/partner_accounts`, { method: 'POST',
    headers: { Authorization: `Bearer ${token.access_token}`, 'Content-Type': 'application/json' },
    body: JSON.stringify({ domain: new URL(settings.origin).hostname }),
  });
  await saveRegistration(settings, localKey);
  console.log('中国区应用注册请求成功。下一步：打开后台测试页，使用普通车主账号授权。');
} catch (e) {
  console.error(e instanceof SafeError ? e.message : '注册未完成，请检查网络、配置和公钥文件');
  process.exitCode = 1;
}
