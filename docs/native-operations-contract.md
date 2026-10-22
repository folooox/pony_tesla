# Staged native operations contract

This is an optional, **not production-wired** adapter under `/api/native/v1`. No server setting, module presence, or history database enables it. Existing server construction does not pass the factory; legacy APIs and native read-only responses retain their defaults. No real Fleet command transport, receiver, operator HTTP API, enable-control endpoint, or iOS integration is added here.

## Constructor and trusted seams

`createNativeRouter(settings, { operationsFactory, ...existingDependencies })` accepts a synchronous, memoized-per-account factory:

```js
operationsFactory(accountId, { authenticateAccount }) => ({
  capture,                 // NativeCaptureStore-compatible interface
  commands,                // CommandService-compatible interface
  ready: { history: true, commands: true }
})
```

Only operator-controlled constructor code may provide this factory. It receives the account ID derived from `NativeAuth.authenticate`, never an HTTP account selector. Omit a dependency or its readiness attestation to keep its routes unavailable (404). History requires all six methods (`list`, `detail`, `annotate`, `deleteRecord`, `deleteAll`, `exportCSV`). Commands require `ready`, `prepare`, `execute`, `status`, `confirm`, an explicit readiness attestation, and a successful synchronous `ready()` check. The deployment owner must verify prerequisites before attesting readiness; this is not a vehicle-capability assertion. `/session` reports trips and charge_history only for ready history, commands only for ready commands, and **always telemetry:false**. A history store alone is not proof of live collection.

Construct capture with the supplied `authenticateAccount` callback. The router passes an opaque, request-scoped object to capture methods; the callback maps it to the authenticated account only during that operation, revalidates its native session, and optionally checks a VIN argument against the freshly authorized VIN. Caller JSON cannot manufacture these objects. A shared capture store must use the same callback from this router (the function is stable across factory calls). The factory owner closes injected capture and command stores, once each; router.close closes only its original read-only stores and auth store. Avoid returning one original read-only HistoryStore for multiple accounts.

Command service receives server-owned object parameters:

- prepare: `{account,vin,context,action}`
- execute: `{account,vin,context,intentId,requestId,action}`
- status/confirm: `{account,vin,context,operationId}`

The service's signed adapter is **account-aware**: `sendSigned(account, vin, command, params)`. Do not bind a shared owner token or infer an account from VIN. `checkAuthorization(account,vin)` must verify current account scopes, pairing, supported actions, online state, and authenticated timestamps. Its readback is trusted upstream data, never HTTP JSON. There is no complete signed Fleet implementation in this change.

## Routes

All requests require a valid native Bearer; Basic is rejected. All responses have `Cache-Control: no-store` and `X-Content-Type-Options: nosniff`. Mutating requests require `application/json` (optional UTF-8 charset), the existing bounded 4 KiB reader, and exact fields. Unknown paths/root return 404. No account selectors are accepted.

| Method | Path | Input / result |
|---|---|---|
| GET | `/vehicles/{VIN}/history` | optional unique `kind=trip\|charge`, `limit=1..100` (default 30), `before` opaque cursor; capture list result `{records,next_cursor,retention_hours,source_policy}` |
| GET | `/vehicles/{VIN}/history/{hexid}` | capture detail result |
| PATCH | same | exactly `{tag,note}` strings; tag ≤30, note ≤500 Unicode characters; prohibited controls rejected |
| DELETE | same | exactly `{confirm:true}`; capture deleteRecord result |
| DELETE | `/vehicles/{VIN}/history` | exactly `{confirm:true}`; clears this account/VIN only |
| GET | `/vehicles/{VIN}/history/{hexid}/export.csv` | UTF-8 CSV; fixed `attachment; filename="pony-history.csv"` (no VIN in filename) |
| POST | `/vehicles/{VIN}/commands/context` | exactly `{}`; returns `{context,vin,expires_in:3600}` |
| POST | `/vehicles/{VIN}/commands/prepare` | exactly `{action:{command,params},context}`; service intent result |
| POST | `/commands/execute` | exactly `{intentId,requestId,action:{command,params},context}`; requestId must equal intentId |
| GET | `/commands/{id}` | service status result; no query/body context; current server selection used |
| POST | `/commands/{id}/confirm` | exactly `{context}`; explicit user-requested readback only |

Record IDs are lowercase 64-character hex. Command IDs use the command service's server-issued format. JSON field casing for command objects follows `native-commands.mjs`. No arbitrary command endpoint escape hatch exists. Malformed query/cursor shape, cursor account/VIN/kind scope, action, and JSON validation occur before Fleet calls. Detail/export accept no query parameters. Capture retains authority over record membership, retention, and cursor semantics.

## Membership, contexts, and admission

Every history operation (including list, delete-all, annotation and CSV), context creation, and command prepare/execute/status/confirm first calls the authenticated account's **fresh `client.vehicles()`** and requires exact VIN membership. Old cache membership is insufficient. All these requests share the original per-account one-in-flight / 30-per-minute admission bucket with vehicles/probe/snapshot. The router never wakes, probes, polls, sends commands, or confirms on its own.

The selection nonce is random, opaque, bound server-side to the authenticated session family, account and VIN. One context exists per family, expires after one hour, and is lost on router restart. Expired contexts are swept before operational resolution and context admission (including intent invalidation), so the bounded 1,000-family map recovers capacity without a process restart. A backwards clock jump invalidates affected selections rather than extending their authority. Every explicit context request invalidates the family's old prepared intents via `commands.store.invalidateContext(account, oldContext)` when that store seam exists. Even without that optional ledger invalidation, old nonces are denied by the router. An old operation cannot cross to the new selection. Multiple device families remain independent. Token refresh within a family preserves selection. Logout revokes the family with unchanged response semantics and clears its context. A revoked/replayed family can no longer use its context. Losing a context does not erase or resolve an uncertain command ledger entry.

A client **must explicitly request a new context for every selection change**, including returning to the same VIN; auth alone does not detect UI changes. Until the future iOS client implements that protocol, do not enable commands in a deployment. Already-dispatched commands are not cancelled by selection changes or logout, and unresolved operations must not be blindly resent. Status reads do not request readback. Only an explicit confirm POST may ask the command service for authenticated readback; a successful HTTP dispatch is not a confirmed vehicle state.

## Evidence / limitations

`backend/native-operations-router.test.mjs` supplies local HTTP fixtures, real NativeAuth PKCE exchange/session validation, real capture persistence and trusted operator/receiver object seams, real command ledger/service, injected local Fleet stubs, and a forbidden external transport. Identity account seeding is a trusted leaf fixture, not public verified JSON or an authentication bypass endpoint. Existing native-router tests remain unchanged and should be run alongside these fixtures by the designated parent runner. Tests were authored but **not executed by this agent**, as requested.

No network inspection, credentials, server execution, deployment, iOS changes, real receiver setup, command scope expansion, pairing, signed transport, real account A/B testing, device testing, or vehicle testing was performed. Factory readiness remains an integration responsibility, not evidence of real-world operation.
