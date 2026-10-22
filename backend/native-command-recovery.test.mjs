import test from 'node:test';
import assert from 'node:assert/strict';
import { generateKeyPairSync, randomUUID, sign } from 'node:crypto';
import { mkdtempSync, realpathSync, rmSync, readFileSync, chmodSync, statSync } from 'node:fs';
import { tmpdir } from 'node:os';
import { join } from 'node:path';
import { DatabaseSync } from 'node:sqlite';
import { CommandService, CommandStore, COMMANDS, COMMAND_APPLICATION_ID, RETENTION_MS } from './native-commands.mjs';
import { RECOVERY_DOMAIN } from './native-command-recovery.mjs';

// Simulated authority ONLY. This does not establish OS/process/proxy termination.
function fixture(t) {
  const dir = mkdtempSync(join(realpathSync(tmpdir()), 'pony-recovery-')), path = join(dir, 'ledger.sqlite');
  let now = 1800000000000, sends = 0, authCalls = 0;
  let store = new CommandStore(path, { clock: () => now });
  const keys = generateKeyPairSync('ed25519');
  const owner = { senderIncarnation: randomUUID(), proxyIncarnation: randomUUID() };
  const state = { readback: null, send: async () => ({ result: true }), receipt: null };
  const issue = (challenge, patch = {}, privateKey = keys.privateKey) => {
    const bytes = Buffer.from(JSON.stringify({ ...challenge, domain: RECOVERY_DOMAIN, issuer: 'offline-authority', keyVersion: '1',
      issuedAt: now, expiresAt: now + 1000, quiescentAt: now, ...patch }));
    return { payload: bytes.toString('base64url'), signature: sign(null, bytes, privateKey).toString('base64url') };
  };
  const service = (selectedStore = store, overrides = {}) => new CommandService({ store: selectedStore, enabled: true, clock: () => now,
    dispatchOwnerProvider: () => owner,
    recoveryReceiptTrust: { issuer: 'offline-authority', keyVersion: '1', publicKey: keys.publicKey },
    obtainRecoveryReceipt: challenge => state.receipt ? state.receipt(challenge) : issue(challenge),
    checkAuthorization: async (account, vin) => {
      authCalls++;
      return { account, vin, checkedAt: now, member: true, keyPaired: true, online: true,
        supported: COMMANDS, scopes: ['vehicle_cmds', 'vehicle_charging_cmds'], readback: state.readback };
    },
    sendSigned: async (...args) => { sends++; return state.send(...args); }, ...overrides,
  });
  let svc = service();
  const input = { account: 'alice', vin: 'LRW3E7EK0NC123456', context: 'selection_context_0001', action: { command: 'door_lock', params: {} } };
  const prepare = async (patch = {}) => {
    const req = { ...input, ...patch }, intent = await svc.prepare(req);
    return { ...req, intentId: intent.intentId, requestId: intent.requestId, operationId: intent.requestId };
  };
  const crash = async (patch = {}, status = 'dispatching', knownOwner = true) => {
    const req = await prepare(patch), row = store.db.prepare('SELECT * FROM command_intents WHERE id=?').get(req.intentId);
    // Commit a fixture crash boundary, NEVER leave a real live promise behind.
    store.transaction(() => {
      store.db.prepare('UPDATE command_intents SET used=1 WHERE id=?').run(row.id);
      store.db.prepare('INSERT INTO command_operations(id,account,vin,context,action,digest,created,dispatched,status,owner,generation) VALUES(?,?,?,?,?,?,?,?,?,?,?)')
        .run(row.id, row.account, row.vin, row.context, row.action, row.digest, now, now, status,
          knownOwner ? JSON.stringify(owner) : null, knownOwner ? randomUUID() : null);
    });
    return req;
  };
  t.after(() => { store.close(); rmSync(dir, { recursive: true, force: true }); });
  return { path, state, owner, service, prepare, crash, issue, input,
    get svc() { return svc; }, get store() { return store; }, get now() { return now; },
    get sends() { return sends; }, get authCalls() { return authCalls; },
    advance(ms = 1) { now += ms; },
    restart() { store.close(); store = new CommandStore(path, { clock: () => now }); svc = service(); },
    readback(timestamp = now, locked = true) { state.readback = { authentic: true, source: 'vehicle_data', vin: input.vin,
      observedAt: now, data: { vehicle_state: { timestamp, locked } } }; },
  };
}
const denied = status => e => e.status === status;

const targetCases = [
  ['window_control', { command: 'vent' }, 'vehicle_state', { fd_window: 1, fp_window: 1, rd_window: 1, rp_window: 1 }],
  ['window_control', { command: 'close' }, 'vehicle_state', { fd_window: 0, fp_window: 0, rd_window: 0, rp_window: 0 }],
  ...['off', 'on', 'dog', 'camp'].map((mode, index) =>
    ['set_climate_keeper_mode', { climate_keeper_mode: index }, 'climate_state', { climate_keeper_mode: mode }]),
  ['remote_seat_heater_request', { heater: 0, level: 3 }, 'climate_state', { seat_heater_left: 3 }],
  ['remote_seat_heater_request', { heater: 1, level: 0 }, 'climate_state', { seat_heater_right: 0 }],
  ...[false, true].map(on =>
    ['remote_steering_wheel_heater_request', { on }, 'climate_state', { steering_wheel_heater: on }]),
  ['charge_port_door_open', {}, 'charge_state', { charge_port_door_open: true }],
  ['charge_port_door_close', {}, 'charge_state', { charge_port_door_open: false }],
  ['set_charge_limit', { percent: 80 }, 'charge_state', { charge_limit_soc: 80 }],
  ['charge_start', {}, 'charge_state', { charging_state: 'Charging' }],
  ['charge_stop', {}, 'charge_state', { charging_state: 'Stopped' }],
];
for (const [command, params, section, fields] of targetCases) {
  test(`target ${command} ${JSON.stringify(params)} requires complete exact post-quiescence readback`, async t => {
    const f = fixture(t), req = await f.prepare({ action: { command, params } });
    assert.equal((await f.svc.execute(req)).status, 'awaiting_readback');
    await f.svc.recover(req); f.advance();
    const [field, expected] = Object.entries(fields)[0];
    const partial = { ...fields }; delete partial[field];
    const wrong = { ...fields, [field]: typeof expected === 'boolean' ? !expected
      : typeof expected === 'number' ? String(expected) : 'Complete' };
    for (const data of [partial, wrong, fields]) {
      f.state.readback = { authentic: true, source: 'vehicle_data', vin: f.input.vin, observedAt: f.now,
        data: { [section]: { timestamp: f.now, ...data } } };
      assert.equal((await f.svc.confirm(req)).status, data === fields ? 'confirmed' : 'awaiting_readback');
      if (data !== fields) {
        assert.equal(f.store.operation('alice', req.operationId).confirmed, null);
        await assert.rejects(f.svc.execute(await f.prepare()), denied(409));
      }
    }
    f.restart(); assert.equal(f.svc.status(req).status, 'confirmed');
    assert.equal(f.sends, 1);
  });
}

for (const action of [
  { command: 'set_preconditioning_max', params: { on: true } },
  { command: 'actuate_trunk', params: { which_trunk: 'front' } },
  { command: 'actuate_trunk', params: { which_trunk: 'rear' } },
]) {
  test(`${action.command} ${JSON.stringify(action.params)} is acknowledged only, never inferred confirmed`, async t => {
    const f = fixture(t), req = await f.prepare({ action });
    assert.equal((await f.svc.execute(req)).status, 'acknowledged');
    f.advance();
    f.state.readback = { authentic: true, source: 'vehicle_data', vin: f.input.vin, observedAt: f.now,
      data: { climate_state: { timestamp: f.now, is_climate_on: true, is_preconditioning: true,
        defrost_mode: 2 }, vehicle_state: { timestamp: f.now, ft: 1, rt: 1 } } };
    assert.equal((await f.svc.confirm(req)).status, 'acknowledged');
    await assert.rejects(f.svc.recover(req), denied(409));
    assert.equal((await f.svc.confirm(req)).status, 'acknowledged');
    assert.equal(f.store.operation('alice', req.operationId).confirmed, null);
    f.restart(); assert.equal(f.svc.status(req).status, 'acknowledged');
    assert.equal(f.sends, 1);
  });
}

test('proof only recovers crash to unknown; separate post-quiescence exact readback releases target', async t => {
  const f = fixture(t), req = await f.crash(); f.restart();
  f.advance(10); f.readback();
  assert.equal((await f.svc.confirm(req)).status, 'unknown');
  const before = f.authCalls;
  assert.equal((await f.svc.recover(req)).status, 'unknown');
  assert.equal(f.authCalls, before); assert.equal(f.sends, 0);
  assert.equal(f.store.operation('alice', req.operationId).confirmed, null);
  await assert.rejects(f.svc.recover(req), denied(409)); // consumed proof cannot run twice
  const next = await f.prepare(); await assert.rejects(f.svc.execute(next), denied(409));
  assert.equal((await f.svc.confirm(req)).status, 'unknown'); // observation equal cutoff
  const cutoff = f.now; f.advance(); f.readback(cutoff);
  assert.equal((await f.svc.confirm(req)).status, 'unknown'); // stale source, fresh fetch
  f.readback(f.now, false); assert.equal((await f.svc.confirm(req)).status, 'unknown');
  f.readback(); assert.equal((await f.svc.confirm(req)).status, 'confirmed');
  assert.equal(f.sends, 0); f.restart(); assert.equal(f.svc.status(req).status, 'confirmed');
});

test('all pending targets including accepted results need signed quiescence, never callback-settled inference', async t => {
  for (const accepted of [false, true]) {
    const f = fixture(t), req = await f.prepare();
    f.state.send = async () => accepted ? { result: true } : { status: 200 };
    await f.svc.execute(req); f.advance(); f.readback();
    const expected = accepted ? 'awaiting_readback' : 'unknown';
    assert.equal((await f.svc.confirm(req)).status, expected);
    assert.equal((await f.svc.recover(req)).status, expected);
    f.advance(); f.readback(); assert.equal((await f.svc.confirm(req)).status, 'confirmed');
    assert.equal(f.sends, 1);
  }
});

test('default unavailable authority, booleans, invalid keys, missing immutable owner and malformed owner deny', async t => {
  const f = fixture(t), req = await f.crash();
  for (const overrides of [{ obtainRecoveryReceipt: undefined }, { recoveryReceiptTrust: null },
    { recoveryReceiptTrust: { issuer: 'x', keyVersion: '1', publicKey: 'invalid' } }]) {
    await assert.rejects(f.service(f.store, overrides).recover(req), denied(503));
  }
  f.state.receipt = () => true; await assert.rejects(f.svc.recover(req), denied(409));
  const other = fixture(t), old = await other.crash({}, 'dispatching', false);
  await assert.rejects(other.svc.recover(old), denied(409));
  const fresh = fixture(t), command = await fresh.prepare();
  await assert.rejects(fresh.service(fresh.store, { dispatchOwnerProvider: () => ({ pid: 123 }) }).execute(command), denied(503));
  assert.equal(fresh.sends, 0);
});

test('forgery, every binding mismatch, freshness and bounded envelopes fail closed', async t => {
  const f = fixture(t), req = await f.crash(); f.advance(10);
  const patches = [
    { ledgerId: randomUUID() }, { account: 'bob' }, { vin: 'LRW3E7EK0NC123457' }, { operationId: 'other' },
    { owner: JSON.stringify({ ...f.owner, senderIncarnation: randomUUID() }) }, { generation: randomUUID() },
    { nonce: 'different' }, { dispatchedAt: f.now }, { status: 'unknown' }, { domain: 'other' },
    { issuer: 'other' }, { keyVersion: '2' }, { issuedAt: f.now + 1 }, { expiresAt: f.now },
    { expiresAt: f.now + 30_001 }, { quiescentAt: f.now - 11 }, { quiescentAt: f.now + 1 },
    { quiescentAt: f.now - 0.5 }, { extra: true },
  ];
  for (const patch of patches) {
    f.state.receipt = challenge => f.issue(challenge, patch);
    await assert.rejects(f.svc.recover(req), denied(409));
    assert.equal(f.store.operation('alice', req.operationId).status, 'dispatching');
  }
  f.state.receipt = challenge => f.issue(challenge, {}, generateKeyPairSync('ed25519').privateKey);
  await assert.rejects(f.svc.recover(req), denied(409));
  for (const envelope of [{ payload: 'x'.repeat(8193), signature: 'x' }, { payload: 'e30=', signature: 'x' }, false]) {
    f.state.receipt = () => envelope; await assert.rejects(f.svc.recover(req), denied(409));
  }
  assert.equal(f.sends, 0);
});

test('new challenge invalidates outstanding old proof; no transaction held during receipt wait', async t => {
  const f = fixture(t), req = await f.crash();
  let entered, release;
  const started = new Promise(resolve => { entered = resolve; });
  f.state.receipt = challenge => new Promise(resolve => { release = () => resolve(f.issue(challenge)); entered(); });
  const first = f.svc.recover(req); await started;
  // Independent handle can issue a newer challenge while the old callback is waiting.
  const otherStore = new CommandStore(f.path, { clock: () => f.now });
  try {
    f.state.receipt = () => false;
    await assert.rejects(f.service(otherStore).recover(req), denied(409));
    release(); await assert.rejects(first, denied(409));
    f.state.receipt = null; assert.equal((await f.svc.recover(req)).status, 'unknown');
  } finally { otherStore.close(); }
});

test('receipt replay from an earlier challenge or operation fails; bounded timeout retains gate', async t => {
  const f = fixture(t), req = await f.crash(); let old;
  f.state.receipt = c => { old = f.issue(c); return false; };
  await assert.rejects(f.svc.recover(req), denied(409));
  f.state.receipt = () => old; await assert.rejects(f.svc.recover(req), denied(409));
  const other = await f.crash({ vin: 'LRW3E7EK0NC123457' });
  await assert.rejects(f.svc.recover(other), denied(409));
  f.state.receipt = () => new Promise(() => {});
  await assert.rejects(f.service(f.store, { recoveryTimeoutMs: 1 }).recover(req), denied(503));
  assert.equal(f.store.operation('alice', req.operationId).status, 'dispatching');
});

test('live promised sender denies even trusted simulated receipts across service and store handles', async t => {
  const f = fixture(t), req = await f.prepare(); let entered, release, receiptCalls = 0;
  const started = new Promise(resolve => { entered = resolve; });
  f.state.send = () => new Promise(resolve => { release = resolve; entered(); });
  f.state.receipt = c => { receiptCalls++; return f.issue(c); };
  const pending = f.svc.execute(req); await started;
  const otherStore = new CommandStore(f.path, { clock: () => f.now });
  try {
    for (const observer of [f.svc, f.service(), f.service(otherStore)]) {
      await assert.rejects(observer.recover(req), denied(409));
    }
    assert.equal(receiptCalls, 0); assert.equal(f.sends, 1);
  } finally { release({ result: true }); await pending; otherStore.close(); }
});

test('recovered unknown momentary operation has no target, remains locked after proof and readback', async t => {
  const f = fixture(t), req = await f.crash({ action: { command: 'honk_horn', params: {} } });
  await f.svc.recover(req); f.advance(); f.readback();
  assert.equal((await f.svc.confirm(req)).status, 'unknown');
  await assert.rejects(f.svc.execute(await f.prepare()), denied(409));
});

test('all unresolved states compact atomically into minimal durable locks across logout/restart/prune', async t => {
  for (const status of ['dispatching', 'unknown', 'awaiting_readback']) {
    const f = fixture(t), req = await f.crash({}, status);
    f.advance(RETENTION_MS); f.store.prune(); f.restart(); f.store.invalidateContext('alice', f.input.context); f.store.prune();
    assert.equal(f.store.operation('alice', req.operationId), undefined);
    const lock = f.store.db.prepare('SELECT * FROM command_safety_locks').get();
    assert.deepEqual(Object.keys(lock).sort(), ['account', 'generation', 'operation', 'owner', 'vin']);
    assert.equal(lock.operation, req.operationId);
    await assert.rejects(f.svc.execute(req), denied(410));
    await assert.rejects(f.svc.execute(await f.prepare({ context: 'selection_context_0002' })), denied(409));
    await assert.rejects(f.svc.recover(req), denied(404));
    assert.equal(f.sends, 0);
  }
});

test('held confirm authorization cannot remove an independently compacted safety lock', async t => {
  const f = fixture(t), req = await f.crash();
  await f.svc.recover(req);
  let entered, release;
  const started = new Promise(resolve => { entered = resolve; });
  const observer = f.service(f.store, { checkAuthorization: (account, vin) => new Promise(resolve => {
    release = () => resolve({ account, vin, checkedAt: f.now, member: true, keyPaired: true, online: true,
      supported: COMMANDS, scopes: ['vehicle_cmds'], readback: f.state.readback });
    entered();
  }) });
  const pending = observer.confirm(req); await started;
  const otherStore = new CommandStore(f.path, { clock: () => f.now });
  try {
    f.advance(RETENTION_MS); otherStore.prune();
    assert.equal(otherStore.operation('alice', req.operationId), undefined);
    const lock = otherStore.db.prepare('SELECT * FROM command_safety_locks').get();
    assert.equal(lock.operation, req.operationId);
    // Return fresh authorization AND exact post-quiescence readback, so confirm
    // reaches its guarded update rather than failing freshness/target checks.
    f.readback(); release(); await assert.rejects(pending, denied(404));
    assert.deepEqual(otherStore.db.prepare('SELECT * FROM command_safety_locks').get(), lock);
    assert.equal(otherStore.operation('alice', req.operationId), undefined);
    await assert.rejects(f.service(otherStore).execute(await f.prepare()), denied(409));
    assert.equal(f.sends, 0);
    f.restart();
    assert.deepEqual(f.store.db.prepare('SELECT * FROM command_safety_locks').get(), lock);
    await assert.rejects(f.svc.execute(await f.prepare()), denied(409));
    assert.equal(f.sends, 0);
  } finally { release(); await pending.catch(() => {}); otherStore.close(); }
});

for (const [settlement, outcome] of [
  ['accepted', { result: true }],
  ['explicit rejection', { result: false, rejected: true }],
  ['malformed result', { status: 200, ok: true }],
  ['thrown error', null],
]) {
  test(`late held ${settlement} cannot erase compacted lock or recreate detailed row`, async t => {
    const f = fixture(t), req = await f.prepare(); let entered, release;
    const started = new Promise(resolve => { entered = resolve; });
    f.state.send = () => new Promise((resolve, reject) => {
      release = () => settlement === 'thrown error' ? reject(new Error('offline transport failure')) : resolve(outcome);
      entered();
    });
    const pending = f.svc.execute(req); await started;
    f.advance(RETENTION_MS); f.store.prune();
    const lock = f.store.db.prepare('SELECT * FROM command_safety_locks').get();
    assert.equal(lock.operation, req.operationId);
    release(); await assert.rejects(pending, denied(410));
    assert.deepEqual(f.store.db.prepare('SELECT * FROM command_safety_locks').get(), lock);
    f.restart();
    assert.deepEqual(f.store.db.prepare('SELECT * FROM command_safety_locks').get(), lock);
    assert.equal(f.store.db.prepare('SELECT COUNT(*) AS n FROM command_safety_locks').get().n, 1);
    assert.equal(f.store.operation('alice', req.operationId), undefined);
    await assert.rejects(f.svc.execute(await f.prepare()), denied(409));
    assert.equal(f.sends, 1);
  });
}

test('marked v1 migration is idempotent and never invents old owner; newer schemas preserve bytes and modes', t => {
  const dir = mkdtempSync(join(realpathSync(tmpdir()), 'pony-migrate-')), path = join(dir, 'v1.sqlite');
  t.after(() => rmSync(dir, { recursive: true, force: true }));
  const db = new DatabaseSync(path);
  db.exec(`PRAGMA application_id=${COMMAND_APPLICATION_ID}; PRAGMA user_version=1;
    CREATE TABLE command_operations(id TEXT,account TEXT,vin TEXT,context TEXT,action TEXT,digest TEXT,
      created INTEGER,dispatched INTEGER,confirmed INTEGER,status TEXT,PRIMARY KEY(account,id));
    INSERT INTO command_operations VALUES('old','alice','LRW3E7EK0NC123456','old-context','{}','old-digest',1,1,NULL,'dispatching');`);
  db.close(); let store = new CommandStore(path); const id = store.ledgerId;
  assert.equal(store.db.prepare('PRAGMA user_version').get().user_version, 2);
  assert.equal(store.operation('alice', 'old').owner, null); store.close();
  store = new CommandStore(path); assert.equal(store.ledgerId, id);
  assert.equal(store.operation('alice', 'old').owner, null); store.close();
  const future = new DatabaseSync(path); future.exec('PRAGMA user_version=3'); future.close();
  chmodSync(path, 0o640); const bytes = readFileSync(path), mode = statSync(path).mode;
  assert.throws(() => new CommandStore(path), denied(503));
  assert.deepEqual(readFileSync(path), bytes); assert.equal(statSync(path).mode, mode);
});

test('transactional recovery re-read rejects changed owner, generation, state or expired receipt', async t => {
  for (const changed of ['owner', 'generation', 'status', 'expiry']) {
    const f = fixture(t), req = await f.crash();
    f.state.receipt = challenge => {
      const envelope = f.issue(challenge);
      if (changed === 'expiry') f.advance(1000);
      else if (changed === 'status') {
        // Model a concurrent adapter result while obtaining external proof.
        f.store.db.prepare("UPDATE command_operations SET status='unknown' WHERE id=?").run(req.operationId);
      } else {
        // Trusted offline CAS fault injection; never an application ownership API.
        f.store.db.prepare(`UPDATE command_operations SET ${changed}=? WHERE id=?`)
          .run(changed === 'owner' ? JSON.stringify({ ...f.owner, proxyIncarnation: randomUUID() }) : randomUUID(), req.operationId);
      }
      return envelope;
    };
    await assert.rejects(f.svc.recover(req), denied(409));
    assert.equal(f.store.operation('alice', req.operationId).quiescent, null);
    assert.equal(f.sends, 0);
  }
});

test('accepted target without configured proof owner cannot confirm from authentic fresh state', async t => {
  const f = fixture(t), svc = f.service(f.store, { dispatchOwnerProvider: undefined, obtainRecoveryReceipt: undefined, recoveryReceiptTrust: null });
  const req = await f.prepare(); await svc.execute(req); f.advance(); f.readback();
  assert.equal((await svc.confirm(req)).status, 'awaiting_readback');
  await assert.rejects(svc.recover(req), denied(503));
  assert.equal(f.store.operation('alice', req.operationId).owner, null);
  await assert.rejects(svc.execute(await f.prepare()), denied(409));
});
