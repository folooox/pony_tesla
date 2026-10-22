import { createHash, randomBytes, randomUUID } from 'node:crypto';
import { DatabaseSync } from 'node:sqlite';
import { mkdirSync, chmodSync, lstatSync, openSync, closeSync } from 'node:fs';
import { dirname, resolve } from 'node:path';
import { validatedOwner, recoveryTrust, verifyRecoveryReceipt } from './native-command-recovery.mjs';
import { SafeError, validVin, isRecord } from './core.mjs';

// Process-wide defense across store handles, keyed by immutable ledger identity.
// This is supplementary only; absence is NEVER termination proof.
const liveDispatches = new Set();
const liveKey = (store, row) => JSON.stringify([store.ledgerId, row.account, row.id, row.owner, row.generation]);
export const RETENTION_MS = 7 * 86400_000;
export const INTENT_MS = 60_000;
const fail = (message, status = 400) => { throw new SafeError(message, status); };
const digest = value => createHash('sha256').update(JSON.stringify(value)).digest('hex');
const bool = v => typeof v === 'boolean';
const integer = (lo, hi) => v => Number.isInteger(v) && v >= lo && v <= hi;
const number = (lo, hi) => v => Number.isFinite(v) && v >= lo && v <= hi;
const oneOf = values => v => values.includes(v);
const entry = (fields = {}, target = null, scope = 'vehicle_cmds') => ({ fields, target, scope });
// No generic endpoint escape hatch. These are individual signed Fleet commands,
// not recipes: climate setup MUST NOT silently issue multiple commands.
const registry = {
  door_lock: entry({}, () => ({ 'vehicle_state.locked': true })),
  door_unlock: entry({}, () => ({ 'vehicle_state.locked': false })),
  auto_conditioning_start: entry({}, () => ({ 'climate_state.is_climate_on': true })),
  auto_conditioning_stop: entry({}, () => ({ 'climate_state.is_climate_on': false })),
  actuate_trunk: entry({ which_trunk: oneOf(['front', 'rear']) }), // Toggle: no inferred target.
  set_sentry_mode: entry({ on: bool }, p => ({ 'vehicle_state.sentry_mode': p.on })),
  honk_horn: entry(), flash_lights: entry(),
  window_control: entry({ command: oneOf(['vent', 'close']) }, p => Object.fromEntries(
    ['fd_window', 'fp_window', 'rd_window', 'rp_window'].map(k => [`vehicle_state.${k}`, p.command === 'close' ? 0 : 1]))),
  charge_port_door_open: entry({}, () => ({ 'charge_state.charge_port_door_open': true }), 'vehicle_charging_cmds'),
  charge_port_door_close: entry({}, () => ({ 'charge_state.charge_port_door_open': false }), 'vehicle_charging_cmds'),
  set_charge_limit: entry({ percent: integer(50, 100) }, p => ({ 'charge_state.charge_limit_soc': p.percent }), 'vehicle_charging_cmds'),
  charge_start: entry({}, () => ({ 'charge_state.charging_state': 'Charging' }), 'vehicle_charging_cmds'),
  charge_stop: entry({}, () => ({ 'charge_state.charging_state': 'Stopped' }), 'vehicle_charging_cmds'),
  set_temps: entry({ driver_temp: number(15, 28), passenger_temp: number(15, 28) }, p => ({
    'climate_state.driver_temp_setting': p.driver_temp, 'climate_state.passenger_temp_setting': p.passenger_temp })),
  set_climate_keeper_mode: entry({ climate_keeper_mode: integer(0, 3) }, p => ({ 'climate_state.climate_keeper_mode': ['off', 'on', 'dog', 'camp'][p.climate_keeper_mode] })),
  set_preconditioning_max: entry({ on: bool }), // Defrost readback varies: acknowledge only until model mapping is verified.
  remote_seat_heater_request: entry({ heater: oneOf([0, 1]), level: integer(0, 3) }, p => ({
    [`climate_state.seat_heater_${({ 0: 'left', 1: 'right', 2: 'rear_left', 4: 'rear_center', 5: 'rear_right' })[p.heater]}`]: p.level })),
  remote_steering_wheel_heater_request: entry({ on: bool }, p => ({ 'climate_state.steering_wheel_heater': p.on })),
};
export const COMMANDS = Object.freeze(Object.keys(registry));
function exact(value, keys) {
  if (!isRecord(value) || ![Object.prototype, null].includes(Object.getPrototypeOf(value))
    || Reflect.ownKeys(value).length !== keys.length || keys.some(k => !Object.hasOwn(value, k))) fail('Invalid command fields');
}
export function normalizeAction(action) {
  exact(action, ['command', 'params']);
  if (typeof action.command !== 'string' || !Object.hasOwn(registry, action.command)) fail('Unsupported command');
  const fields = registry[action.command].fields;
  exact(action.params, Object.keys(fields));
  const params = {};
  for (const key of Object.keys(fields).sort()) {
    if (!fields[key](action.params[key])) fail('Invalid command parameter');
    params[key] = action.params[key];
  }
  return { command: action.command, params };
}
function identity(account, vin, context) {
  if (typeof account !== 'string' || !/^[A-Za-z0-9_-]{1,128}$/.test(account) || !validVin(vin)
    || typeof context !== 'string' || !/^[A-Za-z0-9_-]{16,128}$/.test(context)) fail('Invalid command context');
}
const output = row => row ? { operationId: row.id, requestId: row.id, vin: row.vin,
  action: JSON.parse(row.action), status: row.status === 'dispatching' ? 'unknown' : row.status,
  createdAt: row.created, dispatchedAt: row.dispatched, confirmedAt: row.confirmed } : null;

export const COMMAND_APPLICATION_ID = 1347309380;
function checkDirectories(path) {
  for (let current = path; ; current = dirname(current)) {
    try {
      const stat = lstatSync(current);
      if (stat.isSymbolicLink() || !stat.isDirectory()) fail('Invalid private directory', 503);
    } catch (error) { if (error.code !== 'ENOENT') throw error; }
    if (dirname(current) === current) break;
  }
}

export class CommandStore {
  constructor(path, { clock = Date.now } = {}) {
    if (typeof path !== 'string' || !path || path === ':memory:') fail('Private persistent command ledger required');
    this.clock = clock;
    path = resolve(path);
    checkDirectories(dirname(path));
    mkdirSync(dirname(path), { recursive: true, mode: 0o700 });
    checkDirectories(dirname(path));
    // Precreate privately: never let SQLite create a briefly world-readable file.
    try { closeSync(openSync(path, 'wx', 0o600)); }
    catch (error) { if (error.code !== 'EEXIST') throw error; }
    const stat = lstatSync(path);
    if (stat.isSymbolicLink() || !stat.isFile()) fail('Invalid ledger path', 503);
    this.db = new DatabaseSync(path);
    try {
      const application = this.db.prepare('PRAGMA application_id').get().application_id;
      const version = this.db.prepare('PRAGMA user_version').get().user_version;
      const objects = this.db.prepare("SELECT name FROM sqlite_master WHERE name NOT LIKE 'sqlite_%'").all();
      // Legacy/unmarked auth/history DBs are NOT automatically adopted or migrated.
      if (application !== COMMAND_APPLICATION_ID && (application !== 0 || objects.length || version !== 0)) {
        fail('Not a command ledger database', 503);
      }
      if (version > 2) fail('Command ledger schema is newer than this service', 503);
    } catch (error) { this.db.close(); throw error; }
    // Recheck under the migration write lock before adopting or changing schema.
    try {
      this.transaction(() => {
        const application = this.db.prepare('PRAGMA application_id').get().application_id;
        const version = this.db.prepare('PRAGMA user_version').get().user_version;
        const objects = this.db.prepare("SELECT name FROM sqlite_master WHERE name NOT LIKE 'sqlite_%'").all();
        if (application !== COMMAND_APPLICATION_ID && (application !== 0 || objects.length || version !== 0)) fail('Not a command ledger database', 503);
        if (version > 2) fail('Command ledger schema is newer than this service', 503);
        this.db.exec(`PRAGMA application_id=${COMMAND_APPLICATION_ID};
          CREATE TABLE IF NOT EXISTS command_intents (
            id TEXT PRIMARY KEY, account TEXT NOT NULL, vin TEXT NOT NULL, context TEXT NOT NULL,
            action TEXT NOT NULL, digest TEXT NOT NULL, created INTEGER NOT NULL, expires INTEGER NOT NULL, used INTEGER NOT NULL DEFAULT 0);
          CREATE TABLE IF NOT EXISTS command_operations (
            id TEXT NOT NULL, account TEXT NOT NULL, vin TEXT NOT NULL, context TEXT NOT NULL,
            action TEXT NOT NULL, digest TEXT NOT NULL, created INTEGER NOT NULL,
            dispatched INTEGER NOT NULL, confirmed INTEGER, status TEXT NOT NULL, PRIMARY KEY(account,id));
          CREATE UNIQUE INDEX IF NOT EXISTS command_single_flight ON command_operations(account,vin)
            WHERE status IN ('dispatching','awaiting_readback','unknown');`);
        if (version < 2) {
          // NULL old owners stay unrecoverable: never retroactively assign ownership.
          this.db.exec(`ALTER TABLE command_operations ADD COLUMN owner TEXT;
            ALTER TABLE command_operations ADD COLUMN generation TEXT;
            ALTER TABLE command_operations ADD COLUMN recovery_nonce TEXT;
            ALTER TABLE command_operations ADD COLUMN quiescent INTEGER;
            CREATE TABLE command_ledger_identity (id TEXT PRIMARY KEY);
            CREATE TABLE command_safety_locks (account TEXT NOT NULL, vin TEXT NOT NULL, operation TEXT NOT NULL,
              owner TEXT, generation TEXT, PRIMARY KEY(account,operation));`);
          this.db.prepare('INSERT INTO command_ledger_identity VALUES(?)').run(randomUUID());
          this.db.exec('PRAGMA user_version=2');
        }
      });
      this.ledgerId = this.db.prepare('SELECT id FROM command_ledger_identity').get().id;
      chmodSync(dirname(path), 0o700); chmodSync(path, 0o600);
      this.db.exec('PRAGMA secure_delete=ON; PRAGMA journal_mode=DELETE; PRAGMA synchronous=FULL; PRAGMA busy_timeout=5000;');
    } catch (error) { this.db.close(); throw error; }
  }
  transaction(fn) {
    this.db.exec('BEGIN IMMEDIATE');
    try { const value = fn(); this.db.exec('COMMIT'); return value; }
    catch (e) { this.db.exec('ROLLBACK'); throw e; }
  }
  operation(account, id) { return this.db.prepare('SELECT * FROM command_operations WHERE account=? AND id=?').get(account, id); }
  prune() {
    const now = this.clock();
    this.transaction(() => {
      this.db.prepare('DELETE FROM command_intents WHERE expires<=?').run(now);
      this.db.prepare(`INSERT OR IGNORE INTO command_safety_locks(account,vin,operation,owner,generation)
        SELECT account,vin,id,owner,generation FROM command_operations WHERE created<=?
        AND status IN ('dispatching','unknown','awaiting_readback')`).run(now - RETENTION_MS);
      this.db.prepare('DELETE FROM command_operations WHERE created<=?').run(now - RETENTION_MS);
    });
  }
  invalidateContext(account, context) {
    this.db.prepare('UPDATE command_intents SET used=1 WHERE account=? AND context=?').run(account, context);
  }
  close() { this.db.close(); }
}

export class CommandService {
  constructor({ store, enabled = false, checkAuthorization, sendSigned, clock = store?.clock ?? Date.now, dispatchOwnerProvider, obtainRecoveryReceipt, recoveryReceiptTrust, recoveryTimeoutMs = 2000 } = {}) {
    this.store = store; this.enabled = enabled === true; this.checkAuthorization = checkAuthorization;
    this.sendSigned = sendSigned; this.clock = clock;
    this.dispatchOwnerProvider = dispatchOwnerProvider; this.obtainRecoveryReceipt = obtainRecoveryReceipt;
    this.recoveryTrust = recoveryTrust(recoveryReceiptTrust);
    this.recoveryTimeoutMs = Number.isInteger(recoveryTimeoutMs) && recoveryTimeoutMs > 0 ? Math.min(recoveryTimeoutMs, 5000) : 2000;
  }
  ready() {
    if (!this.enabled) fail('Vehicle commands disabled', 503);
    if (!this.store || typeof this.checkAuthorization !== 'function' || typeof this.sendSigned !== 'function') fail('Command prerequisites unavailable', 503);
  }
  async authorization(account, vin, action) {
    let auth;
    try { auth = await this.checkAuthorization(account, vin); } catch { fail('Command authorization unavailable', 503); }
    const now = this.clock();
    if (!auth || auth.account !== account || auth.vin !== vin || auth.member !== true || auth.keyPaired !== true
      || auth.online !== true || !Array.isArray(auth.supported) || !auth.supported.includes(action.command)
      || !Array.isArray(auth.scopes) || !auth.scopes.includes(registry[action.command].scope)
      || !Number.isSafeInteger(auth.checkedAt) || auth.checkedAt > now || now - auth.checkedAt > 15_000) fail('Command prerequisites not verified', 403);
    return auth;
  }
  async prepare({ account, vin, context, action }) {
    this.ready(); identity(account, vin, context);
    const normalized = normalizeAction(action);
    await this.authorization(account, vin, normalized);
    const now = this.clock(), id = `${now.toString(36)}_${randomBytes(24).toString('base64url')}`;
    this.store.prune();
    this.store.db.prepare('INSERT INTO command_intents(id,account,vin,context,action,digest,created,expires) VALUES(?,?,?,?,?,?,?,?)')
      .run(id, account, vin, context, JSON.stringify(normalized), digest(normalized), now, now + INTENT_MS);
    return { intentId: id, requestId: id, action: normalized, expiresAt: now + INTENT_MS, account, vin, context };
  }
  async execute({ account, vin, context, intentId, requestId, action }) {
    this.ready(); identity(account, vin, context);
    const normalized = normalizeAction(action), hash = digest(normalized);
    if (typeof intentId !== 'string' || intentId !== requestId || !/^[a-z0-9]+_[A-Za-z0-9_-]{32}$/.test(intentId)) fail('Server-issued intent required');
    const replay = () => {
      const row = this.store.operation(account, requestId);
      if (!row) return null;
      if (row.digest !== hash || row.vin !== vin || row.context !== context) fail('Conflicting command replay', 409);
      return output(row);
    };
    const existing = replay(); if (existing) return existing;
    // Authorization is fresh at dispatch, not merely at preview time.
    await this.authorization(account, vin, normalized);
    let owner = null;
    if (this.dispatchOwnerProvider !== undefined) {
      try { owner = validatedOwner(this.dispatchOwnerProvider()); } catch { fail('Dispatch owner unavailable', 503); }
    }
    const generation = randomUUID();
    const start = this.store.transaction(() => {
      const concurrent = replay(); if (concurrent) return { replay: concurrent };
      const row = this.store.db.prepare('SELECT * FROM command_intents WHERE id=? AND account=?').get(intentId, account);
      if (!row || row.expires <= this.clock() || row.used) fail('Command intent expired or consumed', 410);
      if (row.vin !== vin || row.context !== context || row.digest !== hash) fail('Confirmation does not match intent', 409);
      const busy = this.store.db.prepare("SELECT 1 FROM command_operations WHERE account=? AND vin=? AND status IN ('dispatching','awaiting_readback','unknown')").get(account, vin);
      const locked = this.store.db.prepare('SELECT 1 FROM command_safety_locks WHERE account=? AND vin=?').get(account, vin);
      if (busy || locked) fail('Vehicle command unresolved', 409);
      const now = this.clock();
      this.store.db.prepare('UPDATE command_intents SET used=1 WHERE id=?').run(intentId);
      this.store.db.prepare("INSERT INTO command_operations(id,account,vin,context,action,digest,created,dispatched,owner,generation,status) VALUES(?,?,?,?,?,?,?,?,?,?, 'dispatching')")
        .run(requestId, account, vin, context, JSON.stringify(normalized), hash, now, now, owner, generation);
      return { dispatch: true };
    });
    if (start.replay) return start.replay;
    const dispatchRow = this.store.operation(account, requestId), key = liveKey(this.store, dispatchRow);
    liveDispatches.add(key);
    let status = 'unknown';
    try {
      // Adapter contract: explicit safe rejection only if it can prove NO acceptance.
      const result = await this.sendSigned(account, vin, normalized.command, normalized.params);
      if (result?.result === true) status = registry[normalized.command].target ? 'awaiting_readback' : 'acknowledged';
      else if (result?.result === false && result?.rejected === true) status = 'rejected';
    } catch { /* Timeout, transport exception, or malformed upstream response is uncertain. */ }
    liveDispatches.delete(key);
    this.store.db.prepare("UPDATE command_operations SET status=? WHERE account=? AND id=? AND owner IS ? AND generation=? AND status='dispatching'").run(status, account, requestId, owner, generation);
    if (!this.store.operation(account, requestId)) fail('Command details expired; vehicle remains safety locked', 410);
    return output(this.store.operation(account, requestId));
  }
  status({ account, vin, context, operationId }) {
    this.ready(); identity(account, vin, context);
    if (typeof operationId !== 'string' || !/^[a-z0-9]+_[A-Za-z0-9_-]{32}$/.test(operationId)) fail('Invalid operation ID');
    this.store.prune();
    const row = this.store.operation(account, operationId);
    if (!row || row.vin !== vin || row.context !== context) fail('Command operation not found', 404);
    return output(row);
  }
  async recover({ account, vin, context, operationId }) {
    this.status({ account, vin, context, operationId });
    if (typeof this.obtainRecoveryReceipt !== 'function' || !this.recoveryTrust) fail('Recovery authority unavailable', 503);
    const challenge = this.store.transaction(() => {
      const row = this.store.operation(account, operationId);
      if (!row || row.vin !== vin || row.context !== context || !['dispatching', 'unknown', 'awaiting_readback'].includes(row.status)
        || !row.owner || !row.generation || row.quiescent !== null || liveDispatches.has(liveKey(this.store, row))) fail('Recovery not permitted', 409);
      const nonce = randomBytes(32).toString('base64url');
      this.store.db.prepare('UPDATE command_operations SET recovery_nonce=? WHERE account=? AND id=?').run(nonce, account, operationId);
      return Object.freeze({ ledgerId: this.store.ledgerId, account, vin, operationId, owner: row.owner,
        generation: row.generation, dispatchedAt: row.dispatched, status: row.status, nonce });
    });
    let envelope, timer;
    try {
      envelope = await Promise.race([
        Promise.resolve().then(() => this.obtainRecoveryReceipt(challenge)),
        new Promise((_, reject) => { timer = setTimeout(() => reject(new Error('timeout')), this.recoveryTimeoutMs); }),
      ]);
    } catch { fail('Recovery authority unavailable', 503); }
    finally { clearTimeout(timer); }
    this.store.transaction(() => {
      const receipt = verifyRecoveryReceipt(envelope, challenge, this.recoveryTrust, this.clock());
      const row = this.store.operation(account, operationId);
      if (!receipt || !row || row.vin !== vin || row.context !== context || row.owner !== challenge.owner
        || row.generation !== challenge.generation || row.recovery_nonce !== challenge.nonce || row.quiescent !== null
        || row.status !== challenge.status || liveDispatches.has(liveKey(this.store, row))) fail('Recovery proof rejected', 409);
      this.store.db.prepare("UPDATE command_operations SET status=?,quiescent=?,recovery_nonce=NULL WHERE account=? AND id=?")
        .run(row.status === 'dispatching' ? 'unknown' : row.status, receipt.quiescentAt, account, operationId);
    });
    return this.status({ account, vin, context, operationId });
  }
  async confirm({ account, vin, context, operationId }) {
    const current = this.status({ account, vin, context, operationId });
    const row = this.store.operation(account, operationId), action = JSON.parse(row.action);
    // A durable dispatch marker may belong to a live signer in another instance.
    // Even matching fresh state cannot release its slot while that call could still send.
    // Crash markers deliberately remain blocked; never infer owner death from readback.
    if (row.status === 'dispatching' || row.quiescent === null) return current;
    const cutoff = Math.max(row.dispatched, row.quiescent ?? row.dispatched);
    if (!['unknown', 'awaiting_readback'].includes(current.status) || !registry[action.command].target) return current;
    const auth = await this.authorization(account, vin, action), readback = auth.readback;
    // Readback is supplied ONLY by the trusted injected adapter, never request JSON.
    const target = registry[action.command].target(action.params), now = this.clock();
    if (!readback || readback.authentic !== true || readback.source !== 'vehicle_data' || readback.vin !== vin
      || !Number.isSafeInteger(readback.observedAt) || readback.observedAt <= cutoff || readback.observedAt > now
      || now - readback.observedAt > 15_000) return current;
    const matches = Object.entries(target).every(([path, expected]) => {
      const [section, field] = path.split('.');
      // Section timestamp must itself be newer; a fresh HTTP fetch of stale data is insufficient.
      return Number.isSafeInteger(readback.data?.[section]?.timestamp)
        && readback.data[section].timestamp > cutoff
        && readback.data[section].timestamp <= readback.observedAt && readback.data[section][field] === expected;
    });
    if (matches) this.store.db.prepare("UPDATE command_operations SET status='confirmed',confirmed=? WHERE account=? AND id=? AND status=? AND owner IS ? AND generation IS ? AND quiescent IS ?")
      .run(readback.observedAt, account, operationId, row.status, row.owner, row.generation, row.quiescent);
    return this.status({ account, vin, context, operationId });
  }
}
