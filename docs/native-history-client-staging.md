# Native history client staging

## Source interface

`NativeAccountState` owns `let history = NativeHistoryStore()` and exposes these explicit user-action entry points:

- `refreshHistory(_ kind: NativeHistoryKind) async`
- `loadMoreHistory(_ kind: NativeHistoryKind) async`
- `loadHistoryDetail(_ record: NativeHistoryRecord) async`

All capture the selected VIN, guard account busy/session/storage state, serialize UI operations with `busy`, and finalize local-session status. History invalidates before local-session reload, vehicle-list reload, every accepted vehicle selection (including the same VIN), logout, and finalization without a local session. No views below the account-state class were edited.

`NativeHistoryStore` is `@MainActor @Observable`, memory-only. It exposes `tripRecords`, `chargeRecords`, per-kind `Loading`, `Loaded`, `Failed`, `FetchedAt`, `NextCursor`, `Available`, plus `details`, `detailLoading`, `detailFailed`. Availability is optional: nil means unread; false means explicitly unavailable. Its methods are:

- `refresh(kind:vin:client:) async throws`
- `loadMore(kind:vin:client:) async throws`
- `loadDetail(record:vin:client:) async throws`
- `invalidate()`

The client parameter accepts `any NativeHistoryFetching`, a MainActor class-bound protocol with `hasLocalSession`, `sessionInfo()`, `historyList(vin:kind:before:)`, and `historyDetail(vin:id:)`. The real `NativeTeslaClient` conforms. The store also accepts an injectable local clock via `init(now:)`; its default is Date(), without network access.

Only manual refresh checks `/session`. A successful response is a complete snapshot: both verified native deployment and each corresponding feature flag gate both history kinds. Every explicitly withdrawn kind clears its records/details/cursor/time/loading state, and advances its own request generation so late list/detail responses cannot revive it even after reenable; an allowed sibling refresh still completes. A failed refresh instead preserves successful records, fetched time, cursor and per-record quality. Empty successful lists are loaded, not failed. Pagination is explicit, stable-ID/revision-aware, and rejects repeated cursors. Before any page commit or revision shortcut, stable-ID identity (VIN/kind/first-observed time) is checked atomically against both collections and cached details, including detail-only identities. Detail reads require a currently listed record and preserve successful detail on failure. DTO decoding rejects simulation and checks VIN, kind, retention, record ID and source. Views defensively recheck cached detail identity and revision before rendering.

Invalidation changes a generation and clears both kinds and details. Bound late responses cannot repopulate a new selection, even after returning to the same VIN. Auth invalidation also changes the real client's auth generation, preventing another already-bound successful request from surviving a racing 401. No 401 replay or new refresh retry was added. The existing transport's origin/prefix, redirect refusal, body bound, ephemeral/no-store policy and error restrictions remain intact; query items are constructed with URLComponents rather than interpolated query strings.

Records and details are retention-filtered whenever read and pruned at request boundaries. No local polling or timer was added: an already rendered static screen is not guaranteed to rerender exactly at the seven-day boundary. Reads/navigation after expiry filter rows, including after an offline refresh failure. The parent/UI owner should use a presentation-only clock if exact on-screen expiry is required; it must not trigger HTTP.

## Parent-run isolated harness (not executed by this agent)

`tests/history-store/Package.swift` is intended to be copied to `.airbuild/history-store-harness/Package.swift`. Its PonyCore dependency is `../../ios/PonyCore`, relative to that harness root. Copy **both actual app sources**, `ios/Pony/NativeTeslaClient.swift` and `ios/Pony/NativeHistoryStore.swift`, into `Sources/HistoryStoreHarness/`. Copy `tests/history-store/HistoryStoreTests.swift` into `Tests/HistoryStoreHarnessTests/`. `ClientStub.swift` is empty and must not supply substitute types. No symlinks, new Xcode target, pbxproj edits, production account, credentials, auth bypass or HTTP fixture server are needed.

Run the assembled harness on macOS using SwiftPM. Tests use only protocol fixture clients and immutable JSON decoded through real PonyCore DTOs; the actual client is compiled but its Keychain/browser/transport paths are never invoked. Coverage includes manual capability gating, verified-deployment gating, empty success, capability withdrawal, failed-refresh retention, cached detail failure, concurrent delayed trip/charge responses across invalidation, same-VIN reselection generation, VIN/kind/detail-ID rejection, clock-driven expiry, pagination de-duplication/revision regression, and session loss while a detail response is delayed.

This agent ran no commands, tests, builds, network requests or deployment operations. Compilation and test execution remain with the parent runner. No annotation, deletion, export, commands, wake/probe, telemetry collection, demo mapping or production readiness claim was added.
