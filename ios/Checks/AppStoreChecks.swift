import Foundation
import PonyCore

private enum CheckFailure: Error { case failed(String) }

@main
struct AppStoreChecks {
    @MainActor static func main() async throws {
        let suite = "pony-state-checks-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        var count = 0
        func check(_ condition: Bool, _ label: String) throws {
            guard condition else { throw CheckFailure.failed(label) }
            count += 1; print("PASS \(label)")
        }
        let store = AppStore(defaults: defaults)
        await store.refresh()
        try check(store.vehicle != nil && !store.loading, "initial load completes")
        try check(store.canControl, "online fresh data enables controls")
        await store.execute(.quick(.unlock))
        try check(store.vehicle?.locked == false, "acknowledgment updates vehicle")
        try check(store.operations.first?.outcome == .succeeded, "success has operation record")
        await store.execute(.setChargeLimit(110))
        try check(store.vehicle?.chargeLimit == 80 && store.operations.first?.outcome == .failed, "failed command preserves state")
        store.removeControls(IndexSet(integer: 0)); store.addControl(.lights)
        store.moveControls(IndexSet(integer: 3), to: 0)
        let restored = AppStore(defaults: defaults)
        try check(restored.layout.controls.first == .lights, "layout edits survive a new store")
        if let id = store.visibleTrips.first?.id {
            let saved = await store.saveMetadata(id: id, tag: "通勤", note: "测试")
            try check(saved && store.trips.first(where: { $0.id == id })?.note == "测试", "metadata reaches service and UI")
        }
        await store.changeScenario(.offline)
        try check(!store.canControl && store.vehicle?.status == .offline, "offline controls disabled")
        await store.execute(.quick(.unlock))
        try check(store.vehicle?.locked == true && store.operations.isEmpty, "blocked control makes no command record")
        await store.changeScenario(.expired)
        try check(store.failure == .unauthorized && store.vehicle == nil, "expired authorization is explicit")
        await store.changeScenario(.error)
        try check(store.failure == .unavailable && !store.loading, "failure leaves retryable state")
        await store.changeScenario(.empty)
        try check(store.visibleTrips.isEmpty && store.charges.isEmpty && store.failure == nil, "empty data differs from failure")
        await store.changeScenario(.normal)
        await store.deleteDemoHistory()
        try check(store.visibleTrips.isEmpty && store.charges.isEmpty, "delete clears visible data")
        await store.refresh()
        try check(store.visibleTrips.isEmpty, "refresh does not resurrect deleted records")
        let old = Task { await store.changeScenario(.error) }
        await Task.yield()
        await store.changeScenario(.normal)
        await old.value
        try check(store.scenario == .normal && store.failure == nil && store.vehicle != nil, "old scenario failure cannot replace new session")
        print("\(count) AppStore checks passed")
    }
}
