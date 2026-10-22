import test from 'node:test';
import { generateKeyPairSync, randomUUID, sign } from 'node:crypto';
import { RECOVERY_DOMAIN } from './native-command-recovery.mjs';
import assert from 'node:assert/strict';
import { mkdtempSync, rmSync, statSync, readFileSync, realpathSync, mkdirSync, symlinkSync, chmodSync } from 'node:fs';
import { tmpdir } from 'node:os';
import { join } from 'node:path';
import { CommandStore, CommandService, normalizeAction, COMMANDS, COMMAND_APPLICATION_ID, INTENT_MS, RETENTION_MS } from './native-commands.mjs';
import { DatabaseSync } from 'node:sqlite';
import { SafeError } from './core.mjs';

const vin = 'LRW3E7EK0NC123456', otherVin = 'LRW3E7EK0NC123457';
const context = 'selection_context_0001', otherContext = 'selection_context_0002';
const action = (command = 'door_lock', params = {}) => ({ command, params });
function fixture(t, { recovery = false } = {}) {
  const dir = mkdtempSync(join(realpathSync(tmpdir()), 'pony-command-')), path = join(dir, 'private', 'commands.sqlite');
  let now = 1800000000000, sends = 0;
  const clock = () => now;
  let store = new CommandStore(path, { clock });
  const state = { patch: {}, result: { result: true }, readback: null, send: null, auth: null };
  const checkAuthorization = async (account, selected) => {
    if (state.auth) await state.auth();
    return { account, vin: selected, member: true, keyPaired: true, online: true,
      supported: [...COMMANDS], scopes: ['vehicle_cmds', 'vehicle_charging_cmds'], checkedAt: now,
      readback: state.readback, ...state.patch };
  };
  const sendSigned = async (...args) => { sends++; return state.send ? state.send(...args) : state.result; };
  const { publicKey, privateKey } = generateKeyPairSync('ed25519');
  const owner = { senderIncarnation: randomUUID(), proxyIncarnation: randomUUID() };
  const recoveryConfig = recovery ? { dispatchOwnerProvider: () => owner,
    recoveryReceiptTrust: { issuer: 'offline-fixture', keyVersion: '1', publicKey },
    obtainRecoveryReceipt: async challenge => {
      const payload = Buffer.from(JSON.stringify({ ...challenge, domain: RECOVERY_DOMAIN, issuer: 'offline-fixture', keyVersion: '1',
        issuedAt: now, expiresAt: now + 1000, quiescentAt: now }));
      return { payload: payload.toString('base64url'), signature: sign(null, payload, privateKey).toString('base64url') };
    },
  } : {};
  const service = () => new CommandService({ store, enabled: true, clock, checkAuthorization, sendSigned, ...recoveryConfig });
  let svc = service();
  const request = (overrides = {}) => ({ account: 'alice', vin, context, action: action(), ...overrides });
  const prepare = async (overrides = {}) => {
    const input = request(overrides), intent = await svc.prepare(input);
    return { ...input, intentId: intent.intentId, requestId: intent.requestId };
  };
  t.after(() => { store.close(); rmSync(dir, { recursive: true, force: true }); });
  return { state, path, clock, request, prepare,
    recover: req => svc.recover({ ...req, operationId: req.requestId }), get svc() { return svc; }, get store() { return store; }, get sends() { return sends; },
    advance(ms) { now += ms; }, restart() { store.close(); store = new CommandStore(path, { clock }); svc = service(); } };
}
const safe = status => error => error instanceof SafeError && error.status === status;

test('pure allowlist rejects arbitrary endpoints, PIN, fields, coercions and unsafe ranges', () => {
  for (const command of ['remote_start_drive', 'set_valet_mode', 'erase_user_data', 'software_update', '/api/1/vehicles/x', '__proto__']) {
    assert.throws(() => normalizeAction(action(command)), safe(400));
  }
  for (const input of [action('door_lock', { pin: '1234' }), action('window_control', { command: 'close', lat: 0, lon: 0 }),
    action('set_sentry_mode', { on: 1 }), action('set_charge_limit', { percent: 49 }), action('set_charge_limit', { percent: 80.5 }),
    action('set_temps', { driver_temp: NaN, passenger_temp: 22 }), action('set_climate_keeper_mode', { climate_keeper_mode: 4 }),
    action('remote_seat_heater_request', { heater: 3, level: 1 }), action('remote_steering_wheel_heater_request', { level: 3 }),
    { ...action(), extra: true }]) assert.throws(() => normalizeAction(input), safe(400));
  assert.deepEqual(normalizeAction(action('set_temps', { passenger_temp: 22, driver_temp: 21 })),
    action('set_temps', { driver_temp: 21, passenger_temp: 22 }));
});

test('every allowlisted command has deterministic valid fixture; climate never chains', async t => {
  const values = {
    actuate_trunk: { which_trunk: 'front' }, set_sentry_mode: { on: true }, window_control: { command: 'vent' },
    set_charge_limit: { percent: 80 }, set_temps: { driver_temp: 21, passenger_temp: 22 },
    set_climate_keeper_mode: { climate_keeper_mode: 2 }, set_preconditioning_max: { on: true },
    remote_seat_heater_request: { heater: 0, level: 3 }, remote_steering_wheel_heater_request: { on: false },
  };
  for (const command of COMMANDS) assert.equal(normalizeAction(action(command, values[command] ?? {})).command, command);
  const f = fixture(t), req = await f.prepare({ action: action('set_climate_keeper_mode', values.set_climate_keeper_mode) });
  f.state.send = (account, selected, command, params) => {
    assert.equal(account, 'alice');
    assert.equal(selected, vin); assert.equal(command, 'set_climate_keeper_mode'); assert.deepEqual(params, values.set_climate_keeper_mode);
    return { result: true };
  };
  await f.svc.execute(req); assert.equal(f.sends, 1);
});

test('default disabled and missing injected prerequisites fail closed without dispatch', async t => {
  const f = fixture(t);
  await assert.rejects(new CommandService({ store: f.store }).prepare(f.request()), safe(503));
  await assert.rejects(new CommandService({ store: f.store, enabled: true }).prepare(f.request()), safe(503));
  assert.equal(f.sends, 0);
});

test('fresh identity, membership, scopes, pairing, online and per-command support are all required', async t => {
  const f = fixture(t);
  for (const patch of [{ member: false }, { account: 'bob' }, { vin: otherVin }, { keyPaired: false }, { online: false },
    { supported: [] }, { scopes: [] }, { checkedAt: f.clock() - 15001 }, { checkedAt: f.clock() + 1 }]) {
    f.state.patch = patch; await assert.rejects(f.svc.prepare(f.request()), safe(403));
  }
  f.state.patch = {}; const req = await f.prepare();
  f.state.patch = { scopes: [] }; await assert.rejects(f.svc.execute(req), safe(403)); assert.equal(f.sends, 0);
});

test('prepare is vehicle-write free, durable and binds account, VIN, context and exact params', async t => {
  const f = fixture(t), req = await f.prepare({ action: action('set_sentry_mode', { on: true }) });
  assert.equal(f.sends, 0); f.restart();
  await assert.rejects(f.svc.execute({ ...req, account: 'bob' }), safe(410));
  await assert.rejects(f.svc.execute({ ...req, vin: otherVin }), safe(409));
  await assert.rejects(f.svc.execute({ ...req, context: otherContext }), safe(409));
  await assert.rejects(f.svc.execute({ ...req, action: action('set_sentry_mode', { on: false }) }), safe(409));
  await assert.rejects(f.svc.execute({ ...req, intentId: undefined, confirmed: true }), safe(400));
  assert.equal((await f.svc.execute(req)).status, 'awaiting_readback'); assert.equal(f.sends, 1);
});

test('expired, pruned, switched and invented server intents never send', async t => {
  const f = fixture(t), expired = await f.prepare(); f.advance(INTENT_MS);
  await assert.rejects(f.svc.execute(expired), safe(410));
  f.store.prune(); await assert.rejects(f.svc.execute(expired), safe(410));
  const switched = await f.prepare(); f.store.invalidateContext('alice', context);
  await assert.rejects(f.svc.execute(switched), safe(410));
  const id = `${f.clock().toString(36)}_${'x'.repeat(32)}`;
  await assert.rejects(f.svc.execute({ ...switched, intentId: id, requestId: id }), safe(410));
  assert.equal(f.sends, 0);
});

test('duplicate and concurrent exact requests dispatch once; conflicting replay is 409', async t => {
  const f = fixture(t), req = await f.prepare();
  let release; f.state.send = () => new Promise(resolve => { release = resolve; });
  const first = f.svc.execute(req);
  // Flush authorization microtask, then race the same durable key.
  await Promise.resolve();
  assert.equal((await f.svc.execute(req)).status, 'unknown');
  release({ result: true }); await first;
  assert.equal((await f.svc.execute(req)).status, 'awaiting_readback');
  await assert.rejects(f.svc.execute({ ...req, action: action('door_unlock') }), safe(409));
  assert.equal(f.sends, 1);
});

test('single flight includes authorization race, isolates accounts and VINs', async t => {
  const f = fixture(t), a = await f.prepare(), b = await f.prepare(), c = await f.prepare({ account: 'bob' }), d = await f.prepare({ vin: otherVin });
  const results = await Promise.allSettled([f.svc.execute(a), f.svc.execute(b)]);
  assert.equal(results.filter(r => r.status === 'fulfilled').length, 1);
  assert.equal(results.find(r => r.status === 'rejected').reason.status, 409);
  await f.svc.execute(c); await f.svc.execute(d); assert.equal(f.sends, 3);
  await assert.rejects(async () => f.svc.status({ ...a, account: 'bob', operationId: a.requestId }), safe(404));
});

test('context invalidation during asynchronous authorization prevents dispatch', async t => {
  const f = fixture(t), req = await f.prepare();
  f.state.auth = () => { f.store.invalidateContext('alice', context); };
  await assert.rejects(f.svc.execute(req), safe(410)); assert.equal(f.sends, 0);
});

test('all throws and HTTP-only acceptance are unknown, safe rejection distinct, horn/lights acknowledged only', async t => {
  for (const kind of ['throw', 'http', 'false', 'reject', 'horn', 'lights']) {
    const f = fixture(t), command = kind === 'horn' ? 'honk_horn' : kind === 'lights' ? 'flash_lights' : 'door_lock';
    const req = await f.prepare({ action: action(command) });
    if (kind === 'throw') f.state.send = () => { throw new Error('secret PIN token upstream body'); };
    else f.state.result = kind === 'http' ? { status: 200, ok: true } : kind === 'false' ? { result: false } : kind === 'reject' ? { result: false, rejected: true } : { result: true };
    const result = await f.svc.execute(req);
    assert.equal(result.status, kind === 'reject' ? 'rejected' : ['horn', 'lights'].includes(kind) ? 'acknowledged' : 'unknown');
    assert.equal(JSON.stringify(result).includes('secret'), false);
    assert.equal(readFileSync(f.path).includes(Buffer.from('secret PIN')), false);
    await f.svc.execute(req); assert.equal(f.sends, 1);
  }
});

test('crash at durable dispatch boundary is uncertain after restart and never resent', async t => {
  const f = fixture(t), req = await f.prepare();
  // Simulate the committed write immediately before process loss / SDK entry.
  const row = f.store.db.prepare('SELECT * FROM command_intents WHERE id=?').get(req.intentId);
  f.store.db.prepare('UPDATE command_intents SET used=1 WHERE id=?').run(req.intentId);
  f.store.db.prepare("INSERT INTO command_operations(id,account,vin,context,action,digest,created,dispatched,status) VALUES(?,?,?,?,?,?,?,?, 'dispatching')")
    .run(row.id, row.account, row.vin, row.context, row.action, row.digest, f.clock(), f.clock());
  f.restart(); assert.equal((await f.svc.execute(req)).status, 'unknown'); assert.equal(f.sends, 0);
  const next = await f.prepare(); await assert.rejects(f.svc.execute(next), safe(409));
});

test('only authentic strictly newer source timestamps and exact target confirm; HTTP fetch time cannot', async t => {
  const f = fixture(t, { recovery: true }), req = await f.prepare(); const result = await f.svc.execute(req);
  const args = { ...req, operationId: req.requestId };
  await f.recover(req);
  f.advance(100);
  const good = { authentic: true, source: 'vehicle_data', vin, observedAt: f.clock(),
    data: { vehicle_state: { timestamp: f.clock(), locked: true } } };
  for (const patch of [{ authentic: false }, { source: 'cache' }, { vin: otherVin }, { observedAt: result.dispatchedAt },
    { data: { vehicle_state: { timestamp: result.dispatchedAt, locked: true } } },
    { data: { vehicle_state: { timestamp: String(f.clock()), locked: true } } },
    { data: { vehicle_state: { timestamp: f.clock() - 0.5, locked: true } } },
    { data: { vehicle_state: { timestamp: f.clock() + 1, locked: true } } },
    { data: { vehicle_state: { timestamp: f.clock(), locked: false } } }, { data: {} }]) {
    f.state.readback = { ...good, ...patch };
    assert.equal((await f.svc.confirm(args)).status, 'awaiting_readback');
  }
  f.state.readback = good; assert.equal((await f.svc.confirm(args)).status, 'confirmed');
  f.restart(); assert.equal(f.svc.status(args).status, 'confirmed'); assert.equal(f.sends, 1);
});

test('parameterized targets require all exact fields, not partial climate success', async t => {
  const f = fixture(t, { recovery: true }), req = await f.prepare({ action: action('set_temps', { driver_temp: 21, passenger_temp: 22 }) });
  await f.svc.execute(req); await f.recover(req); f.advance(1);
  const args = { ...req, operationId: req.requestId };
  f.state.readback = { authentic: true, source: 'vehicle_data', vin, observedAt: f.clock(),
    data: { climate_state: { timestamp: f.clock(), driver_temp_setting: 21, passenger_temp_setting: 21 } } };
  assert.equal((await f.svc.confirm(args)).status, 'awaiting_readback');
  f.state.readback.data.climate_state.passenger_temp_setting = 22;
  assert.equal((await f.svc.confirm(args)).status, 'confirmed');
});

test('settled transport unknown requires quiescence proof even with matching readback', async t => {
  const f = fixture(t), req = await f.prepare(); f.state.send = () => { throw new Error('timeout'); };
  await f.svc.execute(req); f.advance(1);
  f.state.readback = { authentic: true, source: 'vehicle_data', vin, observedAt: f.clock(),
    data: { vehicle_state: { timestamp: f.clock(), locked: true } } };
  assert.equal((await f.svc.confirm({ ...req, operationId: req.requestId })).status, 'unknown'); assert.equal(f.sends, 1);
});

test('private permissions and seven day pruning cannot resurrect an old request key', async t => {
  const f = fixture(t), req = await f.prepare(); await f.svc.execute(req);
  assert.equal(statSync(f.path).mode & 0o777, 0o600); assert.equal(statSync(join(f.path, '..')).mode & 0o777, 0o700);
  f.advance(RETENTION_MS + 1); f.store.prune(); f.restart();
  await assert.rejects(f.svc.execute(req), safe(410)); assert.equal(f.sends, 1);
  assert.equal(f.store.db.prepare('SELECT COUNT(*) AS n FROM command_operations').get().n, 0);
});

test('SQLite admission protects two independent service/store instances', async t => {
  const f = fixture(t), first = await f.prepare(), second = await f.prepare();
  const otherStore = new CommandStore(f.path, { clock: f.clock });
  let otherSends = 0;
  const other = new CommandService({ store: otherStore, enabled: true,
    checkAuthorization: async (account, selected) => ({ account, vin: selected, member: true, keyPaired: true,
      online: true, checkedAt: f.clock(), supported: COMMANDS, scopes: ['vehicle_cmds'] }),
    sendSigned: async () => { otherSends++; return { result: true }; },
  });
  try {
    await f.svc.execute(first);
    await assert.rejects(other.execute(second), safe(409));
    assert.equal((await other.execute(first)).status, 'awaiting_readback');
    assert.equal(otherSends, 0); assert.equal(f.sends, 1);
  } finally { otherStore.close(); }
});

test('secure deletion enabled; a future schema is rejected without downgrading it', t => {
  const f = fixture(t);
  assert.equal(f.store.db.prepare('PRAGMA secure_delete').get().secure_delete, 1);
  const path = join(mkdtempSync(join(realpathSync(tmpdir()), 'pony-future-schema-')), 'future.sqlite');
  t.after(() => rmSync(join(path, '..'), { recursive: true, force: true }));
  const db = new DatabaseSync(path); db.exec(`PRAGMA application_id=${COMMAND_APPLICATION_ID}; PRAGMA user_version=99`); db.close();
  assert.throws(() => new CommandStore(path), safe(503));
  const reopened = new DatabaseSync(path);
  assert.equal(reopened.prepare('PRAGMA user_version').get().user_version, 99);
  assert.equal(reopened.prepare("SELECT COUNT(*) AS n FROM sqlite_master WHERE name='command_intents'").get().n, 0);
  reopened.close();
});

test('matching readback cannot release a delayed live signer, same store or independent store', async t => {
  for (const crossStore of [false, true]) {
    const f = fixture(t, { recovery: true }), lock = await f.prepare(), unlock = await f.prepare({ action: action('door_unlock') });
    let release, entered;
    const started = new Promise(resolve => { entered = resolve; });
    f.state.send = () => new Promise(resolve => { release = resolve; entered(); });
    const pendingLock = f.svc.execute(lock);
    await started;
    f.advance(100);
    const readback = { authentic: true, source: 'vehicle_data', vin, observedAt: f.clock(),
      data: { vehicle_state: { timestamp: f.clock(), locked: true } } };
    f.state.readback = readback;
    let secondSends = 0;
    const secondStore = crossStore ? new CommandStore(f.path, { clock: f.clock }) : null;
    const observer = crossStore ? new CommandService({ store: secondStore, enabled: true,
      checkAuthorization: async (account, selected) => ({ account, vin: selected, member: true,
        keyPaired: true, online: true, checkedAt: f.clock(), supported: COMMANDS,
        scopes: ['vehicle_cmds'], readback }),
      sendSigned: async () => { secondSends++; return { result: true }; },
    }) : f.svc;
    try {
      const args = { ...lock, operationId: lock.requestId };
      assert.equal((await observer.confirm(args)).status, 'unknown');
      assert.equal(f.store.operation('alice', lock.requestId).status, 'dispatching');
      await assert.rejects(observer.execute(unlock), safe(409));
      assert.equal(f.sends, 1); assert.equal(secondSends, 0);
      release({ result: true }); await pendingLock;
      await f.recover(lock); f.advance(1);
      readback.observedAt = f.clock(); readback.data.vehicle_state.timestamp = f.clock();
      assert.equal((await observer.confirm(args)).status, 'confirmed');
    } finally { secondStore?.close(); }
  }
});

test('crash dispatch marker cannot be released by readback or age without proven termination recovery', async t => {
  const f = fixture(t), req = await f.prepare();
  const row = f.store.db.prepare('SELECT * FROM command_intents WHERE id=?').get(req.intentId);
  f.store.db.prepare('UPDATE command_intents SET used=1 WHERE id=?').run(row.id);
  f.store.db.prepare("INSERT INTO command_operations(id,account,vin,context,action,digest,created,dispatched,status) VALUES(?,?,?,?,?,?,?,?, 'dispatching')")
    .run(row.id, row.account, row.vin, row.context, row.action, row.digest, f.clock(), f.clock());
  f.restart(); f.advance(1);
  f.state.readback = { authentic: true, source: 'vehicle_data', vin, observedAt: f.clock(),
    data: { vehicle_state: { timestamp: f.clock(), locked: true } } };
  assert.equal((await f.svc.confirm({ ...req, operationId: req.requestId })).status, 'unknown');
  f.advance(RETENTION_MS + 1); f.store.prune();
  assert.equal(f.store.operation('alice', req.requestId), undefined);
  assert.equal(f.store.db.prepare('SELECT COUNT(*) AS n FROM command_safety_locks').get().n, 1);
  const opposite = await f.prepare({ action: action('door_unlock') });
  await assert.rejects(f.svc.execute(opposite), safe(409)); assert.equal(f.sends, 0);
});

test('foreign marked and unmarked SQLite databases refused without bytes, modes or schema mutation', t => {
  const root = mkdtempSync(join(realpathSync(tmpdir()), 'pony-command-foreign-'));
  t.after(() => rmSync(root, { recursive: true, force: true }));
  for (const applicationId of [0, 1347309379]) {
    const dir = join(root, `app-${applicationId}`); mkdirSync(dir, { mode: 0o700 });
    const path = join(dir, 'existing.sqlite'), db = new DatabaseSync(path);
    db.exec(`PRAGMA application_id=${applicationId}; PRAGMA user_version=7;
      CREATE TABLE unrelated_private_history(value TEXT); INSERT INTO unrelated_private_history VALUES('preserve');`);
    db.close(); chmodSync(path, 0o640);
    const before = readFileSync(path), fileMode = statSync(path).mode, dirMode = statSync(dir).mode;
    assert.throws(() => new CommandStore(path), safe(503));
    assert.deepEqual(readFileSync(path), before);
    assert.equal(statSync(path).mode, fileMode); assert.equal(statSync(dir).mode, dirMode);
  }
});

test('all directory ancestors and database symlinks rejected, including nonexistent leaf beneath link', t => {
  const root = mkdtempSync(join(realpathSync(tmpdir()), 'pony-command-symlink-'));
  t.after(() => rmSync(root, { recursive: true, force: true }));
  const actual = join(root, 'actual'), alias = join(root, 'alias'); mkdirSync(actual, { mode: 0o700 });
  symlinkSync(actual, alias, 'dir');
  assert.throws(() => new CommandStore(join(alias, 'nested', 'commands.sqlite')), safe(503));
  const realDb = join(actual, 'commands.sqlite'), store = new CommandStore(realDb); store.close();
  const linkedDb = join(root, 'linked.sqlite'); symlinkSync(realDb, linkedDb);
  assert.throws(() => new CommandStore(linkedDb), safe(503));
  const db = new DatabaseSync(realDb);
  assert.equal(db.prepare('PRAGMA application_id').get().application_id, COMMAND_APPLICATION_ID); db.close();
});
