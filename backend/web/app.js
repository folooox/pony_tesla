const byId = id => document.getElementById(id);
async function api(path, options) {
  const response = await fetch(path, options);
  const data = await response.json();
  if (!response.ok) throw new Error(data.error || '请求失败');
  return data;
}
async function run(action, button) {
  button.disabled = true;
  try { await action(); } catch (error) { byId('result').textContent = error.message; }
  finally { button.disabled = false; }
}
byId('list').onclick = () => run(async () => {
  byId('vehicles').replaceChildren();
  byId('probe').disabled = true;
  byId('result').textContent = '正在获取车辆…';
  const { vehicles } = await api('/api/vehicles');
  for (const car of vehicles) {
    const option = document.createElement('option');
    option.value = car.vin;
    option.textContent = `${car.display_name || 'Tesla'} · ${car.vin?.slice(-6)} · ${car.state}`;
    byId('vehicles').append(option);
  }
  byId('probe').disabled = !vehicles.length;
  byId('result').textContent = vehicles.length ? '账号已连接。请选择车辆读取车况。' : '当前授权下没有车辆，请检查车主账号和授权范围。';
}, byId('list'));
byId('probe').onclick = () => run(async () => {
  byId('result').textContent = '正在读取…';
  const result = await api('/api/probe', { method: 'POST', headers: { 'Content-Type': 'application/json' }, body: JSON.stringify({ vin: byId('vehicles').value }) });
  byId('result').textContent = JSON.stringify(result, null, 2);
}, byId('probe'));
api('/api/status').then(status => {
  byId('status').textContent = status.missing.length ? `尚需配置：${status.missing.join('、')}` : (status.authorized ? '已保存 Tesla 授权，可测试读取车辆。' : '应用配置齐全，等待车主登录授权。');
  byId('connect').disabled = Boolean(status.missing.length);
  byId('list').disabled = !status.authorized;
}).catch(error => { byId('status').textContent = error.message; });

api('/api/readiness').then(report => {
  const titles = { configuration: '应用配置', public_key: '公钥文件', registration: '中国区注册', authorization: '车主授权', history: '历史存储', telemetry: '持续采集', native_session: '原生账号会话' };
  const labels = { missing: '待配置', configured: '配置已填写', present: '本地已存在', not_recorded: '尚无成功记录', recorded: '已有成功记录（待实测）',
    configuration_changed: '配置已变化', unreadable: '记录不可读', token_saved: '已保存令牌（待实测）', not_authorized: '未授权', available: '已启用', not_enabled: '未启用', not_connected: '未接通', not_implemented: '尚未实现' };
  const items = Object.entries(report.stages).map(([key, stage]) => {
    const item = document.createElement('li');
    item.textContent = `${titles[key] || key}：${labels[stage.status] || stage.status}${stage.detail ? `。${stage.detail}` : ''}`;
    return item;
  });
  byId('connection-steps').replaceChildren(...items);
  const history = report.stages.history;
  byId('history-status').textContent = history.status === 'available'
    ? `服务器已有 ${history.trips} 段行程、${history.snapshots} 份最近车况。保留 ${history.retention_hours} 小时。`
    : '历史存储未启用。';
}).catch(error => { byId('connection-steps').textContent = error.message; });

byId('history-refresh').onclick = () => run(async () => {
  byId('trips').replaceChildren(); byId('trip-open').disabled = true; byId('trip-export').hidden = true;
  const page = await api('/api/v1/trips?limit=100');
  for (const trip of page.trips) {
    const option = document.createElement('option'); option.value = trip.id;
    option.textContent = `${trip.source === 'simulation' ? '模拟数据' : '采集数据'} · ${new Date(trip.start).toLocaleString()} · ${trip.distance_km == null ? '里程未知' : `${trip.distance_km.toFixed(1)} km`}`;
    byId('trips').append(option);
  }
  byId('trip-open').disabled = page.trips.length === 0;
  byId('trip-result').textContent = page.trips.length ? `已读取 ${page.trips.length} 段行程${page.next_cursor ? '（当前仅显示前 100 段，可通过 API 分页）' : ''}。` : '服务器尚无行程；真实持续采集尚未接通。';
}, byId('history-refresh'));
byId('trips').onchange = () => { byId('trip-export').hidden = true; byId('trip-result').textContent = '已切换行程，请点击查看。'; };
byId('trip-open').onclick = () => run(async () => {
  byId('trip-export').hidden = true;
  const id = byId('trips').value;
  const { trip } = await api(`/api/v1/trips/${encodeURIComponent(id)}`);
  if (id !== byId('trips').value) return;
  byId('trip-result').textContent = JSON.stringify(trip, null, 2);
  byId('trip-export').href = `/api/v1/trips/${encodeURIComponent(id)}/export.csv`;
  byId('trip-export').hidden = false;
}, byId('trip-open'));
