# Native commands: local stage-B foundation (NOT activated)

Only the isolated `backend/native-commands.mjs`, `backend/native-command-recovery.mjs` and their offline test fixtures are implemented. No native route, OAuth scope, production configuration or Swift dispatch path is changed. Default `enabled` is false. No network transport, wake, poll, retry, key material or credentials are present here. Node's built-in `node:sqlite` is required (same runtime family as native auth); no dependency installation.

## Integration API

```js
const store = new CommandStore('/private/native/commands/ledger.sqlite', { clock });
const service = new CommandService({
  store, enabled: false, clock,
  checkAuthorization: async (account, vin) => authorization,
  sendSigned: async (account, vin, command, params) => signedResult,
});
const preview = await service.prepare({ account, vin, context, action: {
  command: 'set_sentry_mode', params: { on: true },
}});
// Present EXACT returned action, account and VIN for a separate explicit user confirmation.
const operation = await service.execute({ account, vin, context,
  action: preview.action, intentId: preview.intentId, requestId: preview.requestId });
const status = service.status({ account, vin, context, operationId: operation.operationId });
const readback = await service.confirm({ account, vin, context, operationId: operation.operationId });
store.invalidateContext(account, context); // on logout/account switch/vehicle switch
store.prune(); // also called by prepare/status; schedule locally to enforce idle retention
store.close();
```

`normalizeAction(action)` is pure; `COMMANDS`, `COMMAND_APPLICATION_ID` (1347309380), `INTENT_MS` (60 seconds), `RETENTION_MS` (7 days) are exported. It requires exactly `{command,params}` and exact command parameter keys, no coercions/defaults/arbitrary endpoints. All errors from authorization are replaced with generic `SafeError`; send exceptions and raw responses are never stored or returned. Adapter error messages must not be logged by future routes.

`account` MUST come from authenticated native session, never request JSON. `context` MUST be a server-owned opaque selection generation, at least 16 URL-safe characters, bound to account/session and selected VIN. Rotate it and call `invalidateContext` on vehicle/account switch, logout and revocation; switching away and back must NOT restore the old generation. Prepare/execute parameters in the example are service-layer objects, **not a proposed trusted HTTP body**. A route must verify session context again before calling execute. Revocation racing authorization requires the adapter to check at the actual dispatch boundary too. Existing native router has no selection-generation or command routes; do not enable until implemented and tested.

Preview checks prerequisites but never writes to vehicle. It writes only a one-use server intent. Boolean `confirmed:true` is not consent. UI must obtain a separate deliberate confirmation after displaying exact normalized action. Execute requires the server intent as BOTH `intentId` and `requestId`; arbitrary client idempotency keys are intentionally unsupported. The 256-bit server ID is not itself a bearer credential: account, VIN and selection-generation binding are also enforced. Durable consumption, operation insertion and single-flight admission happen atomically before any adapter invocation. Intent creation time/expiry and account-bound payload digest are persisted. No operation can be created without the corresponding still-valid unused stored intent.

Exact duplicate returns the existing operation and does NOT call the signer, even after restart or intent expiry. Changed action/VIN/context on an existing key yields 409. Missing or expired intent yields 410. Account-private operation queries yield 404 for a mismatch. Pruning an old operation also removes its old expired intent; reusing that old request ID therefore cannot silently submit again. New action requires new explicit preview/confirmation, not a transparent retry.

### Authorization adapter

`checkAuthorization(account,vin)` must return only verified current server-side facts:

```js
{
  account, vin, member: true, keyPaired: true, online: true,
  checkedAt: clock(), // integer epoch milliseconds, no future time, <=15s old
  scopes: ['vehicle_cmds', 'vehicle_charging_cmds'],
  supported: ['door_lock', /* independently verified per-command capabilities */],
  readback: { // optional except for a useful explicit confirm()
    authentic: true, source: 'vehicle_data', vin,
    observedAt: clock(), // verified source observation, NOT just HTTP receipt time
    data: { vehicle_state: { timestamp: sourceTimestampMs, locked: true } },
  },
}
```

A plain object is not cryptographic proof: this adapter is a trusted boundary, not caller-provided data. Membership must be freshly checked in the account's own authorized list; online, virtual-key pairing, supported command/model/firmware and granted scopes must be verified, not assumed from HTTP success or the presence of a VIN. No online wake is permitted. Fresh authorization is required at prepare, execute and explicit confirm. Do not populate `supported` by blindly copying `COMMANDS` (the tests do that only as deterministic fixtures). Existing OAuth scopes in `core.mjs` remain read-only and are insufficient for activation.

`confirm()` reads only through this adapter; it does not accept client-supplied readback JSON. The adapter may perform one explicitly requested safe `vehicle_data` read, never a background poll or wake. Authenticate VIN and provenance and convert source section timestamps to epoch milliseconds without fabricating them. All pending target confirmations require verified signed quiescence first, even after an accepted adapter reply. Both observation AND relevant section timestamps must be strictly newer than the maximum of durable dispatch and proven quiescence cutoff. Missing, stale, future, wrong-VIN, wrong-target or partially matching fields leave status unchanged. Exact matching target is observational confirmation, not proof of causal attribution to this command.

### Signed adapter (account is mandatory)

`sendSigned(account, vin, command, params)` must select credentials by the supplied verified native account, never a shared vault, ambient current-account variable, or caller-supplied Tesla token. It receives ONLY the normalized allowlisted command and parameters; no free Fleet path. Return a small safe object:

- `{result:true}` only after explicit signed-command acceptance: persistent targets become `awaiting_readback`, **not success**.
- `{result:false,rejected:true}` only with trustworthy explicit evidence that the vehicle did NOT accept the operation: `rejected`.
- Anything else (including `{ok:true,status:200}`, bare `{result:false}`, malformed response, timeout, thrown exception or uncertain rejection): `unknown`.

Do not return upstream bodies, tokens, private keys, PINs or error messages. Never treat HTTP 2xx as command acceptance or state confirmation. TLS-protected official `teslamotors/vehicle-command` command proxy is a potential separate adapter; its process owns signing keys and bearer-token handling. **The official SDK/proxy can perform internal session retries. This service guarantees one adapter invocation per operation, NOT one physical vehicle transmission. Audit SDK/proxy resend/session-retry behavior before activation; an opaque proxy must not be described as never retrying.** There is no adapter implementation or proxy installation in this change.

## Registry / Swift mapping

Reference supplied by parent: Tesla China vehicle command endpoint documentation, `https://developer.tesla.cn/docs/fleet-api/endpoints/vehicle-commands`; scope reference `https://developer.tesla.cn/docs/fleet-api/authentication/overview`. This implementation performs no documentation/network fetch. Allowlist is not evidence of support by PONY's 2022 China Model 3.

| Native surface | Exact Fleet command / body | Readback target / limitation |
|---|---|---|
| lock/unlock | `door_lock` / `door_unlock`, `{}` | `vehicle_state.locked` true/false |
| climate on/off | `auto_conditioning_start` / `auto_conditioning_stop`, `{}` | `climate_state.is_climate_on` |
| frunk/trunk | `actuate_trunk`, `{which_trunk:'front'|'rear'}` | Acknowledged only; actuator/toggle has no safe inferred persistent target |
| sentry | `set_sentry_mode`, `{on:boolean}` | `vehicle_state.sentry_mode` |
| horn/lights | `honk_horn` / `flash_lights`, `{}` | Acknowledged only, never an active flag |
| vent/close windows | `window_control`, `{command:'vent'|'close'}` | All four `vehicle_state.fd_window/fp_window/rd_window/rp_window` must exactly equal 1/0; missing or different representation stays pending. No invented GPS coordinates. Disable if vehicle/official adapter requires coordinates or verified semantics differ |
| charge port open/close | `charge_port_door_open` / `charge_port_door_close`, `{}` | `charge_state.charge_port_door_open` |
| charge limit | `set_charge_limit`, `{percent:integer 50..100}` | `charge_state.charge_limit_soc`; intentionally conservative accepted range |
| charging | `charge_start` / `charge_stop`, `{}` | `charge_state.charging_state` exactly `Charging` / `Stopped`; `Complete` not silently equated |
| temperature | `set_temps`, `{driver_temp:number 15..28,passenger_temp:number 15..28}` | Both `climate_state.*_temp_setting`; conservative Celsius range |
| keeper mode | `set_climate_keeper_mode`, `{climate_keeper_mode:integer 0..3}` | `climate_state.climate_keeper_mode` off/on/dog/camp. Normal/dog/camp is separate from HVAC start; no automatic multi-command recipe |
| defrost | `set_preconditioning_max`, `{on:boolean}` | Acknowledged only until model-specific defrost readback mapping verified; MUST NOT infer defrost from general preconditioning |
| seat heat | `remote_seat_heater_request`, `{heater:0|1,level:integer 0..3}` | Front left/right `climate_state.seat_heater_left/right`. Front IDs only; rear/center/third-row mapping deliberately unavailable until official mapping + target-vehicle capability verification |
| steering heat | `remote_steering_wheel_heater_request`, `{on:boolean}` | `climate_state.steering_wheel_heater`; boolean only |
| Swift integer steering heat | Map only explicit off/on intent to boolean if vehicle supports it | Multi-level steering heat unavailable; do not collapse arbitrary 1..3 levels silently |
| valet/PIN, drive-start, erase, software update | **Unsupported** | No PIN collection/storage, no passthrough command |
| demo `simulateOpening` | **Unsupported** | Never sent to Fleet |

All noncharging commands require `vehicle_cmds`; charge limit/start/stop and charge-port commands require `vehicle_charging_cmds`. Seat IDs, window representations, keeper/steering fields and source timestamp semantics must be verified against official proxy mapping and actual vehicle capabilities before being listed as supported. Missing proof means unavailable, not inferred model support.

## Durable states, uncertainty and retention

`dispatching` is internal durable status; public reads map it to `unknown`, including interruption before/after signer entry. Acceptance cannot be inferred after process death. Unknown operations are NEVER resent. Constructor/restart does not unlock or assign owners to old rows. Adapter settlement only updates the immutable owner+dispatch-generation row while it remains `dispatching`; late completion cannot overwrite recovery or resurrect a pruned row.

SQLite admission checks both the partial single-flight index and durable safety locks within the same `BEGIN IMMEDIATE` transaction. Single-flight applies per account+VIN across store/service instances for `dispatching`, `awaiting_readback`, `unknown`. Accepted one-shot/actuator operations are `acknowledged` (not vehicle-state confirmation); trustworthy explicit rejection is `rejected`. These settled terminal results release their detailed slot. Pending persistent targets only release after **both** signed quiescence evidence and a separate explicit authentic post-cutoff readback. Adapter acceptance, callback settlement, HTTP success, process timeout and matching vehicle state are NOT owner/proxy termination evidence. Unknown momentary operations have no target and remain blocked even after recovery.

### Isolated signed recovery boundary (not a production death authority)

Optional trusted constructor dependencies:

```js
const service = new CommandService({
  store, enabled: false, checkAuthorization, sendSigned,
  dispatchOwnerProvider: () => ({ senderIncarnation, proxyIncarnation }),
  obtainRecoveryReceipt: async challengeDescriptor => boundedSignedEnvelope,
  recoveryReceiptTrust: { issuer, keyVersion, publicKey: supervisorEd25519PublicKey },
  recoveryTimeoutMs: 2000, // positive integer, capped at 5000ms
});
// Explicit server-authenticated selection context; NO caller proof argument:
await service.recover({ account, vin, context, operationId });
// Recovery never sends, authorizes, reads vehicle state, confirms, or releases.
// A distinct deliberate confirm() performs authorization + authentic fresh readback.
await service.confirm({ account, vin, context, operationId });
```

The owner provider is trusted server configuration, not request JSON. It must return exactly two server-owned cryptographic UUID-v4 **runtime incarnations**, one sender and one proxy (not PID, lease, random operation ID or caller assertion). These and a fresh UUID dispatch generation are durably recorded before signer entry, immutable through settlement/recovery. For compatibility with dispatch-only offline fixtures, absent owner provider permits dispatch with NULL owner; **such rows cannot recover or confirm pending targets**. Malformed configured owner fails before send. Marked v1 operations migrate with NULL owners and cannot be retroactively assigned. Production activation requires a genuine owner provider and authority, not this compatibility fallback.

A challenge binds ledger UUID, account, VIN, operation ID, exact serialized immutable owner, dispatch generation, dispatch timestamp, current internal status and a fresh 256-bit nonce. Owner serialization is the exact string supplied in the challenge (do not reserialize it). The signed envelope is exactly `{payload,signature}`: canonical unpadded base64url bytes and Ed25519 signature. `payload` is a UTF-8 JSON object containing **exactly all challenge fields**, plus `domain: 'pony.command-owner-quiescence.v1'`, configured `issuer`, `keyVersion`, and safe-integer epoch milliseconds `issuedAt`, `expiresAt`, `quiescentAt`. Signature verification covers original payload bytes, not reconstructed JSON. Payload is limited to 8192 encoded characters; signature is exactly 64 bytes. Require issue time not future, expiry strictly future, positive TTL <=30 seconds, dispatch <= quiescence <= issue <= now. The pinned key must be Ed25519. Missing key/callback, plain boolean, bad signature, wrong bindings, expiry or malformed envelope fail closed with generic errors.

Receipt acquisition is outside SQLite transactions and bounded by a local timeout; timeout is denial, never quiescence evidence. A new recovery attempt replaces the stored nonce, invalidating older outstanding challenges. Verification and transactional re-read check owner, generation, nonce, state and absence of prior quiescence before consuming the nonce. `dispatching` becomes `unknown`; settled `unknown` remains `unknown`; accepted `awaiting_readback` remains `awaiting_readback`. These changes only store proven quiescence, do not set confirmedAt or release admission. Consumed proof is not reusable. Failed/timeout attempts retain the gate. Same-process live signer promises deny recovery even across independent store handles using ledger UUID identity; this registry is supplementary defense, never the authority or sole proof of death.

**Critical activation blocker:** no real supervisor/OS death-receipt issuer is built in this phase. The authority must first irreversibly revoke admission for these exact sender/proxy incarnations, then prove ALL associated proxy queues, retries, background work and drains are terminated and cannot resume. Random IDs, absence from a local registry, process restart, PID disappearance alone, callback completion, cancellation requests, lease expiry or a live boolean are insufficient. Never install an issuer that signs based on any such assertion. The offline test authority possesses ephemeral test keys only and simulates that external guarantee; it is not a production helper. `recover()` does not expand the existing proxy or expose HTTP. The authority private key must never be available to command callers or the application sender process.

### Seven-day compaction is NOT gate expiry

At age >=7 days, `prune()` atomically replaces **every unresolved detailed operation** (`dispatching`, `unknown`, `awaiting_readback`) with a minimal durable safety lock, then removes detailed rows and expired intents. A lock contains ONLY account, VIN, opaque operation ID, immutable owner binding and dispatch generation: no action, parameters, context, digest, timestamps or readback. It survives restart, logout, selection invalidation and subsequent pruning. Late held sender completion cannot delete the lock or recreate details. New intents may be previewed but execution remains denied. Old request IDs cannot resend because their consumed/expired intents are gone. Expired detail queries/recovery are unavailable, not an implicit release. There is **no API to override, delete, abandon, or confirm a compacted safety lock**. Unknown one-shot operations therefore never age into permission to resend.

This policy does NOT promise all PII deletion after seven days: account/VIN and opaque ownership/operation linkage are sensitive and retained indefinitely in minimal safety locks. Detailed data has seven-day scheduled retention; gate retention has no time-based release. **Owner approval of this indefinite sensitive minimal-lock policy, private backup policy and resulting permanently blocked VIN behavior is required before enabling.** Losing/replacing the ledger to bypass a lock is unsafe, not recovery. Future policy changes require separately reviewed design; no human force-unlock endpoint exists here.

SQLite uses command-specific `application_id=1347309380` (distinct from history/capture), `synchronous=FULL`, rollback journal (not WAL), `secure_delete=ON`, busy timeout, forward-schema rejection, private directory 0700 and DB 0600. Foreign marked databases and unmarked nonempty/schema-versioned databases are refused before permission/schema PRAGMAs or changes, preserving existing auth/history files. New files are exclusively precreated with `openSync(...,'wx',0600)` rather than allowing SQLite a default-permissions creation window. Every existing directory ancestor and the final DB file is checked with lstat; symlinks/non-directory ancestors and nonregular DBs are refused. Use canonical real paths (macOS tests resolve `tmpdir()` through `realpathSync`) and a dedicated private directory owned by the service, not a repository/shared directory. Ancestor checks are not a defense against a privileged attacker swapping paths concurrently: runtime ancestors must not be attacker-writable. These permissions do not replace host access control, disk encryption, backup-retention control or filesystem secure-erasure guarantees. `prune()` securely deletes expired intents and all old detailed operations only after atomically retaining minimal unresolved safety locks; schedule it even when idle. These APIs do not provide disk-level or backup secure erasure. Do not copy the ledger into uncontrolled long-retention backups. The public `db` handle is trusted server internals for offline crash fixtures, never a route API. Schema version **2**: only this marked ledger (or a genuinely empty new database) is initialized/migrated; application/version/emptiness checks are repeated inside `BEGIN IMMEDIATE`. Newer, foreign and unmarked nonempty schemas are refused without byte/mode/schema changes. Reopening a marked v2 ledger does not mint a new ledger identity. v1 missing-owner rows remain unowned and blocked.

## Offline fixtures / outstanding gates

`node --test backend/native-commands.test.mjs backend/native-command-recovery.test.mjs` (parent runner; not run by this implementation agent). Fixtures use `node:test`, strict assertions, injected epoch clock and temporary persistent SQLite. Coverage: command schemas and forbidden commands, climate no-chaining, default-off/missing dependencies, every authorization prerequisite, account/VIN/context isolation, durable preview/expiry/invalidation, exact and conflicting replay, duplicate concurrency, authorization race, SQLite single-flight, dispatch-crash/restart, unknown/safe rejection/acknowledgment, no HTTP-only success, newer authentic readback, partial climate target mismatch, uncertainty resolution, file modes and seven-day replay safety. Tests do not use a server or HTTP.

Remaining gates: parent-run tests; official signer/proxy implementation and retry audit; official heater/window/readback verification; server-owned selection generation/invalidation; refreshed control scopes via explicit owner OAuth consent; fresh membership/capability/key-pair/online adapter; real irreversible sender/proxy quiescence authority and protected trust-key provisioning; owner approval of indefinite minimal sensitive safety-lock retention; private scheduled pruning/backup policy; production-route auth/rate limits and sanitization; Swift UI intent confirmation and truthful pending/unknown state; owner-approved individual real-car tests. No simulator, device, proxy or actual vehicle execution is claimed.


## Parent verification — 2026-10-20 continuation

All backend files were run together with official Node24.21.0 after checksum verification on the macOS builder: **200/200 PASS**, build `0e277b2c-39b8-4e9b-aad5-84b2c8c7dd6a`. This includes the recovery suite, legacy/native auth, capture, optional router and bounded proxy regressions. The router regression now proves unquiesced accepted targets return unchanged without a new authorization/readback and that subsequent execute is still denied; no service behavior was weakened to satisfy its old read-count expectation.

Additional recovery regressions verified: a held confirm across independent-store seven-day compaction cannot remove the resulting lock; late accepted/explicitly rejected/malformed/thrown settlements cannot restore details or remove locks; complete exact window/keeper/front-seat/steering/charging targets are required; defrost and both trunks remain acknowledgment-only even with plausible readback. All use temporary offline fixture ledgers/keys and injected clocks/adapters. This is not actual OS termination proof, proxy deployment, real signing or vehicle acceptance. Foreign-file preservation coverage is for cleanly closed fixture databases, not a verified guarantee for every foreign hot journal/WAL crash-recovery side effect.

