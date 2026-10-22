# Stage A native session contract (implementation, not deployment evidence)

This is the existing **Node 24 self-hosted SQLite backend**, not AirHost. Nothing here adopts the owner's legacy vault or history. Legacy Basic admin routes, `/oauth/start`, and legacy `/oauth/callback` state handling remain intact. Native bearers cannot authenticate admin; Basic cannot authenticate native. No production access or Tesla calls were performed to implement this contract.

## Enable prerequisites (operator approval required)

Disabled by default: `/api/native/v1/*` returns 404. Operator must explicitly configure `NATIVE_ENABLED=1` and `NATIVE_APPROVED_ORIGIN` equal to the configured HTTPS `PUBLIC_ORIGIN`, after approving that origin and arranging server access. Existing Tesla client ID/secret, encryption key, admin config and public HTTPS origin must be complete. No changes to existing keys or upstream registration are made. Tesla's registered redirect remains **`PUBLIC_ORIGIN/oauth/callback`**. Native callback is fixed **`pony-native://auth`**, never registered as a Tesla redirect. Deploy/reverse proxy must preserve Secure cookies and enforce request/header/time limits; disable/redact query/body/Authorization/Cookie/Location logging for authorization and callback routes. Do not expose private storage or backups.

Readiness remains conservative: existing readiness does not claim native deployment, and `/session` returns `native_deployment_verified:false`. Implementation is not proof of deployed or working native sign-in. Commands, telemetry, trips and charge history are unavailable.

## Native login

All API responses are JSON, no-store, no-referrer. POST requires `Content-Type: application/json` (optional UTF-8 charset). No CORS is emitted. Origin, when supplied, must match PUBLIC_ORIGIN; arbitrary web origins and `null` are rejected. Native apps omit Origin. No Basic header on any native route. No bearer on start/browser/exchange/refresh.

1. Generate RFC7636 verifier (43–128 unreserved ASCII chars), S256 challenge (43 base64url chars), and cryptographically random app state (16–128 base64url chars). Retain verifier and state locally; compare returned state before exchange.
2. `POST /api/native/v1/auth/start` body:
   ```json
   {"code_challenge":"<base64url SHA256(verifier)>","callback":"pony-native://auth","state":"<app state>"}
   ```
   Returns `{"authorization_url":"https://<approved-host>/api/native/v1/auth/browser?request=<opaque>","expires_in":600}`. Open this URL with ASWebAuthenticationSession, callback scheme `pony-native`. The URL contains no Tesla credentials.
3. Browser GET consumes the opaque request once, creates an independent cookie-bound OAuth state and nonce, and redirects to China Tesla's official read-only consent. Cookie is HttpOnly, Secure, SameSite=Lax, restricted to `/oauth/callback`. No scripts or third-party content are served.
4. Shared Tesla callback routes only `native.` states to the native handler, never falls back for invalid native states, consumes state once, and clears its cookie on success/error. Cancellation returns safe error JSON; app handles cancelled ASWebAuthenticationSession locally. Complete cancellation/expiry requires a new start. No automatic consent retry.
5. Server exchanges code with existing client secret + official China Fleet audience. ID token **must** pass RS256 signature against fixed `https://auth.tesla.cn/oauth2/v3/discovery/thirdparty/keys`, exact issuer `https://auth.tesla.cn/oauth2/v3/nts`, configured audience (azp required for multiple audiences), exact nonce, valid iat/exp and nonempty sub. No decoded-only identity, email/VIN identity, token-selected JWKS, or absent-ID-token fallback. Unknown claims are not used. Safe failure never saves tokens to any vault. Browser/requests/grants/state persist with explicit expiration across server restart.
6. Redirect is only `pony-native://auth?grant=<opaque>&state=<app-state>`. Grant lifetime 60 seconds, single use and PKCE-bound. No Tesla tokens in redirect. Native app verifies state then calls:
   `POST /api/native/v1/auth/exchange`
   ```json
   {"grant":"<opaque>","code_verifier":"<original verifier>","callback":"pony-native://auth"}
   ```
   Response:
   ```json
   {"access_token":"<opaque>","refresh_token":"<opaque>","token_type":"Bearer","expires_in":900,"refresh_expires_in":2592000,"account_id":"<opaque UUID>"}
   ```
   Store app credentials in Keychain, not UserDefaults. Failed PKCE consumes the grant. Never log credentials.

## Rotation and logout

`POST /api/native/v1/auth/refresh`, **without Authorization**, JSON `{"refresh_token":"<token>"}` returns same session response. Access lifetime is at most 15 min; refresh family absolute lifetime at most 30 days (rotation never extends it). Refresh rotates once atomically in SQLite. Replay of a used refresh revokes the whole family, including the winning request's tokens. Serialize app refreshes; do not retry an ambiguous network failure with the old refresh token indefinitely. Reauthenticate if necessary. Access and refresh tokens are stored only as hashes in native SQLite. Valid rotation additionally has its **own durable per-session-family quota**, independent of anonymous peer buckets: at most6 successful rotations per60-second family window and4096 successful rotations over the family's lifetime (initial issuance is not a rotation). Both counters and token consumption/issuance commit atomically. This supports2880 normal15-minute rotations over30days. A current unused refresh token over either quota returns429 without consuming it or creating rows; minute exhaustion can be retried after the window, but lifetime exhaustion requires a new sign-in. A previously used refresh token is checked **before** both quotas and still revokes its family even when either quota is exhausted. Expired access rows are pruned during rotation/normal cleanup; used refresh hashes remain replay tombstones through absolute family expiry. Each family can mint at most4097 refresh credentials including the initial token. The additive SQLite migration preserves sessions/replay records and backfills lifetime rotation counts from existing refresh rows.

`POST /api/native/v1/auth/logout`, Authorization `Bearer <access_token>`, JSON `{}` revokes that session family and returns `{"logged_out":true,"tesla_revoked":false,"data_deleted":false}`. It does NOT revoke Tesla consent, delete account/history, or log out other session families. Clear local Keychain session. Account deletion is not implemented and no success is claimed.

## Protected read-only routes

Authorization `Bearer <access_token>` is mandatory. No route accepts an account selector, and protected routes reject query parameters. No hidden owner fallback.

- `GET /api/native/v1/session`: `{"account_id":"<opaque UUID>","features":{"vehicles":true,"probe":true,"snapshot":true,"commands":false,"telemetry":false,"charge_history":false,"trips":false},"native_deployment_verified":false}`.
- `GET /api/native/v1/vehicles`: `{"vehicles":[{"vin":"<authorized VIN>","display_name":"<optional name>","state":"asleep"}]}`. Account-scoped TeslaClient projection. This does not wake/probe a vehicle. No auto polling.
- `POST /api/native/v1/vehicles/{VIN}/probe`, JSON `{}`: explicit user action only; existing TeslaClient probe response shape, including `connected`, `live_data`, `vehicle`, `capability`, `message`, and only for actual live data `fetched_at` + `data`. Fifteen-second per-account cooldown and lock. No wake or command route.
- `GET /api/native/v1/vehicles/{VIN}/snapshot`: `{"snapshot":<existing HistoryStore snapshot shape>}` including `vehicle`, `capability`, `data`, `fetched_at`, `source:"vehicle_data"`, `cached:true`, `stale`. 404 when no cache. Fresh account-authorized vehicle list is checked BEFORE any cache read, and before probe; removed vehicles return 403 even if cached. Same VIN in two accounts still uses separate stores. Cache retains existing seven-day retention/staleness semantics, not invented telemetry/history.

Unsupported routes/methods return 404. Safe errors are `{"error":"<nonsecret message>"}`; invalid/expired auth 401, origin/vehicle denial 403, no cache/unsupported 404, timeout 408, oversized 413, JSON type 415, rate/cooldown 429, upstream invalid/unavailable 502, capacity/config failure 503. No upstream bodies or stack traces returned or logged.

## Storage and limits

Stable native account UUID maps only verified issuer+sub. SQLite: `<PRIVATE_DIR>/native/sessions.sqlite`, mode0600 in private directory0700. Each account uses `<PRIVATE_DIR>/native/accounts/<uuid>/tokens.enc.json` (existing AES-GCM Vault, mode0600) and separate `history.sqlite`. Legacy `<PRIVATE_DIR>/tokens.enc.json` and history.sqlite are never read/migrated by native code.

Pending entries have independent durable pools:50 unstarted requests,100 cookie-bound OAuth states,100 verified identity handoff grants; expired entries are pruned. Filling starts cannot consume completion/grant reserves. The OAuth-state pool can itself saturate at100 (for example, admitted browser starts that are abandoned); an unstarted request's browser continuation may then return429 and be consumed, requiring a new start after capacity/expiry recovers. Reserved grants protect already-bound callbacks from anonymous start-only pool pressure, not a claim that every browser continuation always survives floods. Anonymous admission is per `socket.remoteAddress` only, never Forwarded/X-Forwarded-For:20 start attempts/min and a separate40 invalid-credential completion attempts/min, with at most1024 source buckets (expired buckets discarded; new sources fail closed at capacity). There is no shared global auth counter. Valid bound callbacks, valid request/browser continuations, valid grant+PKCE exchanges, and valid refresh credentials bypass anonymous-failure budgets, including replayed refresh credentials that must revoke their family. Valid refresh rotation remains subject to its separate durable family quota described above; browser continuations still require available OAuth-state pool capacity. A saturated peer may not start new logins until its start window resets, but already-established valid credential completions/refresh survive unrelated anonymous floods. Behind a reverse proxy the peer is the proxy: new-start admission is consequently shared for that proxy; do not enable untrusted forwarded-header identity to work around this.

All vehicle/list/snapshot/probe operations share a per-account30 admitted operations/min budget and at most one in-flight Fleet operation. Concurrent excess returns429 without contacting Fleet. Admitted snapshots always make a fresh authorized vehicle-list request: no membership cache or stale coalescing weakens removed-vehicle denial. Existing TeslaClient probe additionally checks membership itself (two list calls for one admitted probe); that duplicate read is intentionally preserved rather than changing core behavior. Session/logout do not spend the Fleet budget, and another account has its own independent budget/lock.

Bodies max4096 bytes, native URL/aggregate header checks8192 bytes, POST body timeout10sec. **Only initial native token exchange and JWKS responses** use bounded nativeJSON (20sec upstream timeout, max128KiB JSON); subsequent existing TeslaClient Fleet/refresh calls retain core requestJSON behavior (20sec timeout, no body-size cap). The nativeJSON response limit must not be interpreted as a bound on every Fleet response. JWKS max32 keys, cache5min, refresh at most once per30sec including unknown kid. Account client cache max100 per process, failing closed at capacity (no eviction of active rotating-refresh queues). Sessions/replay metadata survive restart; expired families are pruned during authorization activity. No arbitrary key URLs are fetched.

**Deployment limitation:** operate one Node server process for account Tesla refresh/probe serialization; SQLite native session rotation is atomic across connections, but per-account TeslaClient queues, Fleet budgets/in-flight caps and cooldown locks are process-local. Horizontal multi-process operation is not supported until distributed serialization is added. No account-deletion UI/API, telemetry ingestion, scheduled history collection, command support or legacy migration is implemented.

## Fixture validation (parent runs; not executed here)

`backend/native-auth.test.mjs`: locally generated RSA/JWK/JWT, injected clock/fetch and temporary SQLite; identity validation, restart/permissions, account stability, grants, token hashing, refresh replay/family revocation, durable per-family6/minute and4096 lifetime rotation quotas with replay-priority/row bounds and additive migration, logout and expiry.

`backend/native-router.test.mjs`: fixture-only router/server flows, callback and cookie/PKCE handling, admin/native separation, account isolation including same VIN, removal-before-cache authorization, explicit probe lock/cooldown, list/snapshot concurrent-burst and per-account budget denial, anonymous start/bogus-exchange floods preserving valid callback/exchange/refresh and grant reserves, ignored forged forwarding headers, disabled gates and unsupported routes. Existing backend test files remain unchanged. Suggested parent command on Node24: `node --test backend/*.test.mjs`. No fixture contacts real Tesla endpoints; injected transport is mandatory for identity/provider tests.
