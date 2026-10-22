# Native signed-command proxy: local source / staging prerequisites

## Status and boundary

This is a **default-disabled local adapter**, not an installed proxy, deployment,
production configuration, route, or proof of a successful vehicle command. No
credentials, network calls, servers, or tests were executed to implement it.
The tests are deterministic `node:test` source using an injected EventEmitter
request transport and injected timers; they do not make external calls.

`backend/native-signed-proxy.mjs` uses Node's `https.request`, not fetch. It sends
one POST to `/api/1/vehicles/{VIN}/command/{allowlisted_command}`, with a bounded
JSON body and an account-scoped bearer credential obtained privately. Connection
address is **only `127.0.0.1`**, IPv4; TLS identity is **`localhost`**. A reviewed,
explicit PEM CA certificate is mandatory for enablement. TLS certificate and
hostname verification remain on (`rejectUnauthorized: true`); no custom
verification hook, URL, host, servername, redirect option or arbitrary request
options are accepted. Port must be a number, integer 1–65535. No proxy is bundled.

The boundary duplicates the 19-command official Fleet allowlist and conservative
parameter bounds in `native-commands.mjs` without importing its SQLite dependency.
Keep these two registries aligned during future review. It rejects extra fields,
unknown commands, caller tokens, accessor parameters, coercions, malformed VINs,
and generic endpoint/path escape hatches before reading any credential. A
trusted native account identifier and uppercase valid VIN are explicit inputs.
The adapter validates syntax, **not ownership or authorization**.

## API and integration (not wired by this change)

Both `new NativeSignedProxy(config, dependencies)` and
`createNativeSignedProxy(config, dependencies)` are exported. `dependencies`
**must** contain `accessToken(account)`, a trusted server-side callback returning
a string or Promise of a string from the account's private credential store.
There is no caller-supplied token argument. Disabled or invalid requests never
invoke this callback. The adapter neither stores nor returns tokens; it creates
the required bearer header only inside its one-shot dispatch. Do not log request
options, injected transport objects, callback errors, or response bodies in
surrounding code; Node's live request necessarily carries its Authorization
header in memory. No credential is attached to the public adapter object.

The default-disabled integration shape is:

```js
import { createNativeSignedProxy } from './native-signed-proxy.mjs';

const proxy = createNativeSignedProxy({}, {
  accessToken: account => privateNativeCredentialStore.accessToken(account),
});
// CommandService's injected sender uses this explicit native-account signature:
const sendSigned = (account, vin, command, params) =>
  proxy.sendSigned(account, vin, command, params);
```

`privateNativeCredentialStore` above is an integration placeholder, not an added
store or bypass. Do not bind the existing browser/admin Tesla account globally.
If an integration expects `sendSigned(vin, command, params)`, use a trusted
server-side account closure, never an account copied from unverified request JSON.
The command foundation must still check membership, command scope, online state,
key pairing, supported command, fresh authorization, confirmation, and its durable
intent/operation ledger **before** sending. Charging commands require
`vehicle_charging_cmds`; other listed commands require `vehicle_cmds`. This change
adds neither scopes nor OAuth behavior: existing read-only scopes stay unchanged.

## Restrictive enablement guard

Only after all staging prerequisites below have been independently satisfied may
trusted local server code construct an enabled instance with these fields:

- `enabled: true` (boolean; absent means disabled).
- `port`: the reviewed loopback listener's numeric port.
- `ca`: the explicitly trusted PEM CA certificate; parsed as a CA certificate.
  Its trust provenance, rotation and the proxy's `localhost` certificate must be
  reviewed independently. No insecure TLS mode exists.
- `deadlineMs`: integer 1–30000, default 10000; total elapsed deadline including
  credential lookup, connect, TLS negotiation, upload and response.
- `audit.release`: reviewed pinned release/source revision label (1–128 ASCII
  letters, digits, dot, underscore or hyphen; not a floating `main` deployment).
- `audit.sourceDigest`: `sha256:` plus 64 lowercase hex characters for the reviewed
  official source artifact. Record the exact artifact and provenance out of band.
- `audit.officialSourceReviewed: true` and
  `audit.retransmissionPolicyReviewed: true`.

Those evidence fields are required attestations, **not cryptographic verification
of the running binary**. The adapter cannot inspect which binary is listening or
prove that a digest matches a deployed process. Placeholder test evidence is not
valid live evidence. No installed/reviewed/pinned release is asserted here.

Before enablement, a reviewer must pin and verify an official
`teslamotors/vehicle-command` release or source revision and source digest; review
build provenance and all relevant dependencies; validate mandatory HTTPS,
loopback-only binding, key storage/permissions, CA trust, `localhost` SAN and
rotation, allowed egress and safe log redaction. Verify account isolation, native
OAuth grants with necessary command scopes, vehicle ownership, virtual-key pairing,
and the command service's persistent ambiguity/replay/readback policies. Do not
expose this listener externally or put this guard into a public request body.

**Official SDK retransmission policy review is still an outstanding live-enable
prerequisite.** Review the pinned proxy's REST forwarding, HTTP 421 rerouting,
vehicle.Execute handling, protocol retries/retransmissions and command-specific
replay behavior. A current-main source inspection is not that pinned audit.

## Outcomes, uncertainty and limits

Every send resolves to a safe constant-vocabulary object:

- `{ status: 'accepted', cause: 'proxy_acknowledged', result: true }` only for HTTP
  200 with JSON `response.result === true`. This is a proxy acknowledgment, **not
  verified car state or physical execution**. Require newer authentic vehicle
  readback where the command foundation supports it.
- `{ status: 'rejected', cause, result: false, rejected: true }` only for a proven
  local non-dispatch: disabled adapter, invalid request, missing provider, or
  credential failure/invalid credential. The public constructor requires a
  provider, so missing-provider is defensive rather than normal configuration.
- `{ status: 'unknown', cause }` for transport/response error, abort, deadline,
  non-200 (including redirects/421), malformed or excessive response, and a proxy
  negative result. The latter is deliberately **not** proof of no earlier vehicle
  acceptance: upstream may have internally retried. No raw upstream reason,
  response body, HTTP headers, token or Error escapes the adapter.

The adapter itself does not retry, wake the vehicle, follow redirects, refresh a
credential, or issue any second command. It buffers at most 16 KiB of response
payload and destroys both streams on overflow or deadline; oversized chunks are
not retained. Deadline can resolve before a stuck credential provider finishes;
the provider itself cannot be canceled, but its late completion cannot dispatch.
Aborts and uncertain outcomes must not trigger automatic command resend.

**No end-to-end exactly-once claim is made.** Even though this adapter makes only
one HTTPS request per valid send, the official proxy/SDK can perform internal
retries/rerouting/protocol exchanges. This source does not disable or change
those internals. Duplicate calls to the adapter are not deduplicated here; the
parent command service owns durable replay handling. Only test injection accepts
a request implementation or timers; treat those dependencies as trusted code,
not runtime request configuration.

## Official references supplied for this review

- Fleet vehicle commands:
  <https://developer.tesla.cn/docs/fleet-api/endpoints/vehicle-commands>
- Authentication/scope overview:
  <https://developer.tesla.cn/docs/fleet-api/authentication/overview>
- Official vehicle-command README (proxy TLS mandatory):
  <https://github.com/teslamotors/vehicle-command>
- Current-main proxy source inspected upstream by the parent reviewer:
  <https://raw.githubusercontent.com/teslamotors/vehicle-command/main/pkg/proxy/proxy.go>
  reports default `MaxAttempts` 2 in REST forwarding, HTTP 421 rerouting, and
  `vehicle.Execute` internal protocol handling. `main` is mutable and is not a
  pinned release or permission to enable.

Tests are left for the parent to run locally, without a live proxy:
`node --test backend/native-signed-proxy.test.mjs`. Coverage exercises TLS options,
loopback-only dispatch, enablement evidence, schemas, secret/error redaction,
non-200/redirects, malformed and bounded responses, aborts, throws and deadlines
with no resend. It does not establish live TLS interoperability, actual SDK retry
semantics, valid production grants, virtual-key pairing, or real vehicle behavior.
